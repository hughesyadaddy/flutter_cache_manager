import 'dart:io';

import 'package:flutter_cache_manager/src/storage/cache_info_repositories/cache_info_repository.dart';
import 'package:flutter_cache_manager/src/storage/cache_info_repositories/helper_methods.dart';
import 'package:flutter_cache_manager/src/storage/cache_object.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;

const _tableCacheObject = 'cacheObject';

class CacheObjectProvider extends CacheInfoRepository
    with CacheInfoRepositoryHelperMethods {
  sqflite.Database? db;
  String? _path;
  String? databaseName;

  /// Either the path or the database name should be provided.
  /// If the path is provided it should end with '{databaseName}.db',
  /// for example: /data/user/0/com.example.example/databases/imageCache.db
  CacheObjectProvider({String? path, this.databaseName}) : _path = path;

  @override
  Future<bool> open() async {
    if (!shouldOpenOnNewConnection()) {
      return openCompleter!.future;
    }
    final path = await _getPath();
    await File(path).parent.create(recursive: true);

    db = await _openDatabase(path);

    return opened();
  }

  Future<sqflite.Database> _openDatabase(String path) async {
    if (Platform.isWindows) {
      sqflite_ffi.sqfliteFfiInit();
      var databaseFactory = sqflite_ffi.databaseFactoryFfi;
      return await databaseFactory.openDatabase(
        path,
        options: sqflite_ffi.OpenDatabaseOptions(
          version: 3,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    } else {
      return await sqflite.openDatabase(
        path,
        version: 3,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }
  }

  Future<void> _onCreate(sqflite.Database db, int version) async {
    await db.execute('''
      create table $_tableCacheObject (
        ${CacheObject.columnId} integer primary key,
        ${CacheObject.columnUrl} text,
        ${CacheObject.columnKey} text,
        ${CacheObject.columnPath} text,
        ${CacheObject.columnETag} text,
        ${CacheObject.columnValidTill} integer,
        ${CacheObject.columnTouched} integer,
        ${CacheObject.columnLength} integer
      );
      create unique index $_tableCacheObject${CacheObject.columnKey}
      ON $_tableCacheObject (${CacheObject.columnKey});
    ''');
  }

  Future<void> _onUpgrade(
      sqflite.Database db, int oldVersion, int newVersion) async {
    if (oldVersion <= 1) {
      var alreadyHasKeyColumn = false;
      try {
        await db.execute('''
          alter table $_tableCacheObject
          add ${CacheObject.columnKey} text;
        ''');
      } on sqflite.DatabaseException catch (e) {
        if (!e.isDuplicateColumnError(CacheObject.columnKey)) rethrow;
        alreadyHasKeyColumn = true;
      }
      await db.execute('''
        update $_tableCacheObject
          set ${CacheObject.columnKey} = ${CacheObject.columnUrl}
          where ${CacheObject.columnKey} is null;
      ''');

      if (!alreadyHasKeyColumn) {
        await db.execute('''
          create index $_tableCacheObject${CacheObject.columnKey}
            on $_tableCacheObject (${CacheObject.columnKey});
        ''');
      }
    }
    if (oldVersion <= 2) {
      try {
        await db.execute('''
          alter table $_tableCacheObject
          add ${CacheObject.columnLength} integer;
        ''');
      } on sqflite.DatabaseException catch (e) {
        if (!e.isDuplicateColumnError(CacheObject.columnLength)) {
          rethrow;
        }
      }
    }
  }

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) {
    if (cacheObject.id == null) {
      return insert(cacheObject);
    } else {
      return update(cacheObject);
    }
  }

  @override
  Future<CacheObject> insert(CacheObject cacheObject,
      {bool setTouchedToNow = true}) async {
    final id = await db!.insert(
      _tableCacheObject,
      cacheObject.toMap(setTouchedToNow: setTouchedToNow),
    );
    return cacheObject.copyWith(id: id);
  }

  @override
  Future<CacheObject?> get(String key) async {
    final List<Map<dynamic, dynamic>> maps = await db!.query(_tableCacheObject,
        columns: null, where: '${CacheObject.columnKey} = ?', whereArgs: [key]);
    if (maps.isNotEmpty) {
      return CacheObject.fromMap(maps.first.cast<String, dynamic>());
    }
    return null;
  }

  @override
  Future<int> delete(int id) {
    return db!.delete(_tableCacheObject,
        where: '${CacheObject.columnId} = ?', whereArgs: [id]);
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) {
    return db!.delete(_tableCacheObject,
        where: '${CacheObject.columnId} IN (${ids.join(',')})');
  }

  @override
  Future<int> update(CacheObject cacheObject, {bool setTouchedToNow = true}) {
    return db!.update(
      _tableCacheObject,
      cacheObject.toMap(setTouchedToNow: setTouchedToNow),
      where: '${CacheObject.columnId} = ?',
      whereArgs: [cacheObject.id],
    );
  }

  @override
  Future<List<CacheObject>> getAllObjects() async {
    return CacheObject.fromMapList(
      await db!.query(_tableCacheObject, columns: null),
    );
  }

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async {
    return CacheObject.fromMapList(await db!.query(
      _tableCacheObject,
      columns: null,
      orderBy: '${CacheObject.columnTouched} DESC',
      where: '${CacheObject.columnTouched} < ?',
      whereArgs: [
        DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch
      ],
      limit: 100,
      offset: capacity,
    ));
  }

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async {
    return CacheObject.fromMapList(await db!.query(
      _tableCacheObject,
      where: '${CacheObject.columnTouched} < ?',
      columns: null,
      whereArgs: [DateTime.now().subtract(maxAge).millisecondsSinceEpoch],
      limit: 100,
    ));
  }

  @override
  Future<bool> close() async {
    if (!shouldClose()) return false;
    await db!.close();
    return true;
  }

  @override
  Future<void> deleteDataFile() async {
    await _getPath();
  }

  @override
  Future<bool> exists() async {
    final path = await _getPath();
    return File(path).exists();
  }

  Future<String> _getPath() async {
    Directory directory;
    if (_path != null) {
      directory = File(_path!).parent;
    } else {
      directory = await getApplicationSupportDirectory();
    }
    await directory.create(recursive: true);
    if (_path == null || !_path!.endsWith('.db')) {
      _path = join(directory.path, '$databaseName.db');
    }
    await _migrateOldDbPath(_path!);
    return _path!;
  }

  Future<void> _migrateOldDbPath(String newDbPath) async {
    if (Platform.isWindows) {
      var databaseFactory = sqflite_ffi.databaseFactoryFfi;
      final oldDbPath =
          join(await databaseFactory.getDatabasesPath(), '$databaseName.db');
      if (oldDbPath != newDbPath && await File(oldDbPath).exists()) {
        try {
          await File(oldDbPath).rename(newDbPath);
        } on FileSystemException {
          // If we cannot read the old db, a new one will be created.
        }
      }
    } else {
      final oldDbPath =
          join(await sqflite.getDatabasesPath(), '$databaseName.db');
      if (oldDbPath != newDbPath && await File(oldDbPath).exists()) {
        try {
          await File(oldDbPath).rename(newDbPath);
        } on FileSystemException {
          // If we cannot read the old db, a new one will be created.
        }
      }
    }
  }
}
