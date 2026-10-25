import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group(
    'native image download task',
    () {
      late Directory directory;
      late HttpServer server;
      late _DownloadSource source;
      var pageRequests = 0;
      Completer<void>? firstPageGate;
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN3sAAAAASUVORK5CYII=',
      );
      final originalCover = [...png, 7, 8];

      setUpAll(() async {
        directory = await Directory.systemTemp.createTemp(
          'venera-download-test-',
        );
        App.dataPath = directory.path;
        App.cachePath = '${directory.path}/cache';
        appdata.settings['proxy'] = 'direct';
        appdata.settings['ehDirectConnection'] = true;
        appdata.settings['language'] = 'en-US';
        await rhttp.Rhttp.init();
        await AppTranslation.init();
        await JsEngine().init();
        await ComicSourceManager().init();
        await LocalManager().init();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.uri.path == '/delayed-page') {
            await firstPageGate?.future;
          }
          if (request.uri.path.startsWith('/page')) pageRequests++;
          if (request.uri.path == '/unavailable-cover' ||
              request.uri.path == '/page-error') {
            request.response.statusCode = HttpStatus.serviceUnavailable;
          } else {
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(
              request.uri.path == '/good-cover' ? originalCover : png,
            );
          }
          await request.response.close();
        });
        source = _DownloadSource('http://127.0.0.1:${server.port}');
        ComicSourceManager().add(source);
      });

      setUp(() {
        pageRequests = 0;
        source.pagePaths = ['/page-0', '/page-1'];
      });

      tearDownAll(() async {
        for (final task in LocalManager().downloadingTasks) {
          task.pause();
        }
        await server.close(force: true);
        ComicSourceManager().remove(source.key);
        JsEngine().dispose();
        LocalManager().dispose();
        await directory.delete(recursive: true);
      });

      Future<LocalComic> download(
        String id, {
        bool chaptered = false,
        bool validCover = false,
        void Function(ImagesDownloadTask)? onStart,
      }) async {
        final task = ImagesDownloadTask(
          source: source,
          comicId: id,
          comic: ComicDetails.fromJson({
            'title': id,
            'comicId': id,
            'sourceKey': source.key,
            'cover':
                '${source.base}/${validCover ? 'good-cover' : 'unavailable-cover'}',
            'tags': {},
            if (chaptered) 'chapters': {'one': 'One'},
          }),
        );
        final result = Completer<LocalComic>();
        void check() {
          final local = LocalManager().find(task.id, task.comicType);
          if (!result.isCompleted && local != null) result.complete(local);
          if (!result.isCompleted && task.isError) {
            result.completeError(StateError(task.message));
          }
        }

        task.addListener(check);
        LocalManager().addListener(check);
        try {
          onStart?.call(task);
          LocalManager().addTask(task);
          final local = await result.future.timeout(
            const Duration(seconds: 12),
          );
          expect(task.progress, 1);
          expect(task.isError, isFalse);
          return local;
        } finally {
          task.removeListener(check);
          LocalManager().removeListener(check);
          task.pause();
          LocalManager().downloadingTasks.remove(task);
          await LocalManager().saveCurrentDownloadingTasks();
        }
      }

      test('unreachable cover does not stop downloading pages', () async {
        final local = await download('cover-failure');
        expect(pageRequests, 2);
        expect(await local.coverFile.readAsBytes(), png);
        expect(await File('${local.baseDir}/0.png').readAsBytes(), png);
        expect(await File('${local.baseDir}/1.png').readAsBytes(), png);
      });

      test(
        'progress includes completed pages while an earlier page is slow',
        () async {
          firstPageGate = Completer<void>();
          source.pagePaths = ['/delayed-page', '/page-1'];
          late ImagesDownloadTask task;
          final completed = download(
            'out-of-order-pages',
            validCover: true,
            onStart: (value) => task = value,
          );
          try {
            final deadline = DateTime.now().add(const Duration(seconds: 4));
            while (DateTime.now().isBefore(deadline)) {
              if (task.tasks[1]?.isComplete == true) break;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(await File('${task.path}/1.png').exists(), isTrue);
            expect(task.progress, 0.5);
            expect(task.message, '1/2');
            expect(task.toJson()['downloadedCount'], 0);
          } finally {
            firstPageGate!.complete();
            await completed;
            firstPageGate = null;
          }
        },
      );

      test(
        'chaptered comics get a root cover copied from the first page',
        () async {
          final local = await download(
            'chaptered-cover-failure',
            chaptered: true,
          );
          expect(pageRequests, 2);
          expect(local.cover, 'cover.png');
          expect(await local.coverFile.readAsBytes(), png);
          expect(await File('${local.baseDir}/one/0.png').readAsBytes(), png);
        },
      );

      test('a successful original cover is preserved', () async {
        final local = await download('original-cover', validCover: true);
        expect(await local.coverFile.readAsBytes(), originalCover);
        expect(pageRequests, 2);
      });

      test('page failures still fail the task', () async {
        source.pagePaths = ['/page-error'];
        await expectLater(
          download('page-failure', validCover: true),
          throwsStateError,
        );
      });

      test(
        'no cover and no pages reports an error without creating a local comic',
        () async {
          source.pagePaths = [];
          await expectLater(
            download('empty-pages'),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'No images available to use as cover.',
              ),
            ),
          );
        },
      );
    },
    skip: Platform.environment['RHTTP_NATIVE_TESTS'] != '1',
  );
}

class _DownloadSource implements ComicSource {
  _DownloadSource(this.base);
  final String base;
  List<String> pagePaths = [];
  @override
  String get key => 'download_fixture';
  @override
  LoadComicPagesFunc get loadComicPages =>
      (_, _) async => Res(pagePaths.map((path) => '$base$path').toList());
  @override
  GetImageLoadingConfigFunc get getImageLoadingConfig =>
      (_, _, _) async => {};
  @override
  Map<String, dynamic> Function(String) get getThumbnailLoadingConfig =>
      (_) => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
