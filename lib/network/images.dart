import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart' as js;
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';
import 'jm_direct_connection.dart';

abstract class ImageDownloader {
  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      if (sourceKey == 'jm' && appdata.settings['jmDirectConnection'] == true) {
        await js.JsEngine().runCode(
          'JmNetwork.prepareImage(ComicSource.sources.jm)',
        );
      }
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var buffer = <int>[];
    await for (final progress in downloadImageBytes(
      dio,
      requestUrl,
      configs['data'],
      sourceKey,
    )) {
      if (progress.imageBytes != null) {
        buffer = progress.imageBytes!;
      } else {
        yield progress;
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return _loadComicImage(imageKey, sourceKey, cid, eid);
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource!.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
          )) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        var buffer = <int>[];
        await for (final progress in downloadImageBytes(
          dio,
          configs['url'] ?? imageKey,
          configs['data'],
          sourceKey,
        )) {
          if (progress.imageBytes != null) {
            buffer = progress.imageBytes!;
          } else {
            yield progress;
          }
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([
            Uint8List.fromList(buffer),
          ]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }

  /// Buffer each attempt separately so a broken stream cannot concatenate data
  /// from two CDNs. The caller applies the source's original image transform.
  static Stream<ImageDownloadProgress> downloadImageBytes(
    AppDio dio,
    String url,
    dynamic data,
    String? sourceKey,
  ) async* {
    final policy = JmDirectConnection.instance;
    final uri = Uri.parse(url);
    final candidates =
        sourceKey == 'jm' &&
            appdata.settings['jmDirectConnection'] == true &&
            dio.options.method == 'GET' &&
            data == null
        ? policy.imageCandidates(uri)
        : [uri];
    for (var i = 0; i < candidates.length; i++) {
      try {
        final response = await dio.request<ResponseBody>(
          candidates[i].toString(),
          data: data,
        );
        final body =
            response.data ?? (throw StateError('Empty image response'));
        final total = body.contentLength < 0 ? null : body.contentLength;
        final buffer = <int>[];
        await for (final bytes in body.stream) {
          buffer.addAll(bytes);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: total,
          );
        }
        if (total != null && buffer.length != total) {
          throw StateError('Incomplete image response');
        }
        if (candidates.length > 1) policy.imageSucceeded(uri, candidates[i]);
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: buffer.length,
          imageBytes: Uint8List.fromList(buffer),
        );
        return;
      } catch (error) {
        if (i == candidates.length - 1 ||
            (error is DioException &&
                (error.type == DioExceptionType.cancel ||
                    (error.response != null &&
                        ![
                          403,
                          404,
                          408,
                          500,
                          502,
                          503,
                          504,
                        ].contains(error.response!.statusCode))))) {
          rethrow;
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    } catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    } finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
