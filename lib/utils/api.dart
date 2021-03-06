import 'dart:convert';
import 'dart:io';
import 'dart:async';


import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:http/http.dart' as http;
import 'package:path/path.dart';

import 'package:p2pmessage/utils/udp.dart';

final String host = "http://192.168.1.101:80";
final String udpSendPort = '1234';
final String udpRecvPort = '4321';

Database db;
Map userProfile;
P2PClient client = P2PClient();

// 初始化数据库
Future initDB() async {
  var dbPath = await getDatabasesPath();
  dbPath = join(dbPath, 'app.db');

  db = await openDatabase(
    dbPath,
    version: 1,
    onCreate: (Database dataBase, int version) async {
      // MESSAGE
      //    status: 0:发送失败，1:已发送，2: 已阅读
      print('Init DataBase');
      await dataBase.execute(
        """
        CREATE TABLE MESSAGE (
            id          INTEGER UNIQUE
                                PRIMARY KEY ASC AUTOINCREMENT,
            from_userid INTEGER REFERENCES USER (id)
                                NOT NULL,
            to_userid   INTEGER REFERENCES USER (id)
                                NOT NULL,
            status      INT     DEFAULT (1),
            content     TEXT,
            ts          INTEGER
        );
        """
      );
      await dataBase.execute(
        """
        CREATE TABLE CONTACTS (
            id          INTEGER      PRIMARY KEY ASC AUTOINCREMENT
                                    UNIQUE
                                    NOT NULL,
            name        TEXT (50)    NOT NULL
                                    UNIQUE,
            address     TEXT (10),
            avatar      CHAR (50)    DEFAULT default_avatar,
            email       CHAR (20),
            last_online INTEGER,
            status      INTEGER
        );
        """
      );
    }
  );

  // syncDataFromServerWithLoop();

  return;
}

// 同步数据
syncDataFromServerWithLoop() {
  new Timer.periodic(new Duration(seconds: 5), (t) {
    print('looping');
  });
}

Future prepareUserProfile() async {
  SharedPreferences.getInstance().then((prefs) {
    // 从本地加载
    String localUserProfile = prefs.getString('user');
    if (localUserProfile == null) {
      return false;
    }

    try {
      Map localUserProfileMap = jsonDecode(localUserProfile);
      userProfile = localUserProfileMap;
      return true;
    } catch (e) {
      return false;
    }
  });
}

// 通用post方法
post(String path, Map params) async {
  var resp = await http.post(host + path, body: params);
  Map error = {
    'success': false
  };
  try {
    var respJson = jsonDecode(resp.body);
    return respJson is Map ? respJson : error;
  } catch (e) {
    print(e);
    return error;
  }
}

login(String username, String pwd) async {
  return await post('/login', { 'username': username, 'password': pwd });
}

signin(String username, String pwd) async {
  return await post('/signin', { 'username': username, 'password': pwd });
}

collectMessages(int userid) async {
  var res = await post('/messages', { 'userid': userid.toString() });

  if (res['success']) {
    List ms = res['data'];

    // 将消息同步到本地数据库
    await mergeMessageToDB(ms);
  }
  // 从本地数据库拉取最近的消息
  return await collectRecentMessageFromDB(userid);
}

collectContacts(int userid) async {
  var res = await post('/contacts', { 'userid': userid.toString() });
  if (res['success']) {
    List contactList = res['data'];
    await mergeContactToDB(contactList);
    return await collectContactFromDB();
  }
  return [];
}

send(int fromUserid, int toUserid, String content, String ts) async {
  var res = await post('/send', {
    'from_userid': fromUserid.toString(),
    'to_userid': toUserid.toString(),
    'content': content,
    'ts': ts
  });

  if (res['success']) {
    var id = res['id'];
    mergeMessageToDB([[id, fromUserid, toUserid, content, int.parse(ts)]]);
  }

  return res['success'];
}

uploadImg(int userid, File image) async {
  var request = http.MultipartRequest('POST', Uri.parse(host + '/upload-img'));
  request.fields['userid'] = userid.toString();
  request.files.add(await http.MultipartFile.fromPath('img', image.path));
  var resp = await request.send();
  try {
    var res = jsonDecode(await resp.stream.bytesToString());
    if (res['success']) {
      res['img_url'] = host + '/avatar/' + res['img_url'];
    }
    return res;
  } catch (e) {
    return e;
  }
}

updateUser(int userid, Map userInfo) async {
  return await post('/update-user', {
    'userid': userid.toString(),
    'user_info': json.encode(userInfo)
  });
}

// 退出登录
logout() async {
  var prefs = await SharedPreferences.getInstance();
  prefs.remove('user');

  var dbPath = await getDatabasesPath();
  dbPath = join(dbPath, 'app.db');

  await deleteDatabase(dbPath);

  return;
}

// 发起p2p连接,向服务器注册信息
startConnection(int userid, int touserid) async {
  var res = await post('/update-connection/start', {
    'from_uid': userid.toString(),
    'from_port': udpSendPort.toString(),
    'to_uid': touserid.toString().toString()
  });

  return res;
}

// 获取连接状态
fetchConnection(int cid) async {
  return await post('/update-connection/fetch', {
    'cid': cid.toString()
  });
}

// 同意对方发起的连接请求
replyConnection(int cid) async {
  return await post('/update-connection/reply', {
    'cid': cid.toString(),
    'to_port': udpRecvPort.toString()
  });
}

// 尝试连接后,向服务器通知
tryConnection(int cid) async {
  return await post('/update-connection/reply', {
    'cid': cid.toString()
  });
}

collectRecentMessageFromDB(int userid) async {
  Map unReadMap = {};
  List unReadList = [];

  List ms = await db.rawQuery(
    """
    SELECT m.id, m.status, m.content, m.ts, u.id as uid, u.name as uname, u.avatar, u.address, u.email, u.last_online, u.status as ustatus
          FROM MESSAGE AS m INNER JOIN CONTACTS as u
          ON (m.to_userid = $userid AND m.from_userid = u.id)
          OR (m.from_userid = $userid AND m.to_userid = u.id)
    """
  );
  // 将原始的数据加工成所需的数据
  for (var m in ms) {
    var uid = m['uid'];
    bool isUnRead = uid != userid && m['status'] == 1;
    if (unReadMap.containsKey(uid)) {
      unReadMap[uid]['latestMsgContent'] = m['content'];
      unReadMap[uid]['latestMsgTs'] = m['ts'] > unReadMap[uid]['latestMsgTs'] ? m['ts'] : unReadMap[uid]['latestMsgTs'];
      if (isUnRead) {
        unReadMap[uid]['unReadCount'] ++;
      }
    } else {
      unReadMap[m['uid']] = Map<String, dynamic>.from({
        'user': {
          'id': m['uid'],
          'avatar': m['avatar'],
          'name': m['uname'],
          'address': m['address'],
          'email': m['email'],
          'last_online': m['last_online'],
          'status': m['ustatus']
        },
        'latestMsgContent': m['content'],
        'latestMsgTs': m['ts'],
        'unReadCount': isUnRead ? 1 : 0
      });
    }
  }
  // 将map中的数组取出来
  for (var key in unReadMap.keys) {
    unReadList.add(unReadMap[key]);
  }
  unReadList.sort((a, b) => b['latestMsgTs'] - a['latestMsgTs']);

  return unReadList;
}

collectMessageFromDB(int userid) async {
  // 从本地数据库中读取聊天记录
  List<Map> list = await db.rawQuery(
    """
    SELECT * FROM MESSAGE WHERE from_userid = ${userid} OR to_userid = ${userid}
    """
  );

  return list.map((m) => new Map<String, dynamic>.from(m)).toList();
}

collectContactFromDB() async {
  // 从本地数据库中读取联系人
  List<Map> list = await db.rawQuery('SELECT * FROM CONTACTS');
  return list.map((m) => new Map<String, dynamic>.from(m)).toList();
}

mergeMessageToDB(List msgs) async {
  // 将未读消息合并到本地数据库
  var sql = '''
    INSERT OR REPLACE INTO MESSAGE (id, from_userid, to_userid, status, content, ts)
    VALUES (?, ?, ?, ?, ?, ?)
  ''';
  var batch = db.batch();
  for (var msg in msgs) {
    batch.rawInsert(sql, msg);
  }
  await batch.commit();
}

mergeContactToDB(List contacts) async {
  var sql = '''
    INSERT OR REPLACE INTO CONTACTS (id, name, avatar, address, email, last_online, status)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  ''';
  var batch = db.batch();
  for (var contact in contacts) {
    batch.rawInsert(sql, contact);
  }
  await batch.commit();
}