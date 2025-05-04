import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ProCounsellor/screens/dashboards/counsellorDashboard/counsellor_base_page.dart';
import 'package:ProCounsellor/screens/dashboards/userDashboard/base_page.dart';
import 'package:ProCounsellor/services/api_utils.dart';

import 'agora_service.dart';
import 'firebase_notification_service.dart';

const String appId = "118a5a8d61b242fdab4fc18f7f6c5479";

class AudioCallScreen extends StatefulWidget {
  final String channelId;
  final bool isCaller;
  final String callerId;
  final String receiverId;
  final Future<void> Function() onSignOut;

  const AudioCallScreen({
    Key? key,
    required this.channelId,
    required this.isCaller,
    required this.callerId,
    required this.receiverId,
    required this.onSignOut
  }) : super(key: key);

  @override
  _AudioCallScreenState createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen> {
  late RtcEngine agoraEngine;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _joined = false;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _callAnswered = false; // ✅ Track if call is answered
  Timer? _ringingTimer;

  Timer? _callTimer;
  int _callDurationInSeconds = 0;
  String _formattedDuration = "00:00";

  bool _isEnding = false;
  StreamSubscription<DatabaseEvent>? _callEndSubscription;

  String callerName = '';
  String callerPhoto = '';
  bool callerIsCounsellor = false;

  String receiverName = '';
  String receiverPhoto = '';
  bool receiverIsCounsellor = false;

  bool _remoteUserJoined = false;

  @override
  void initState() {
    super.initState();
    _fetchCallerAndReceiverDetails();
    _initAgora();
    if (widget.isCaller) _playRingtone();

    listenForCallEnd(widget.channelId);
  }

  // When receiver will cut the call in incoming call page
  void listenForCallEnd(String channelId) {
  if (_isEnding) return;

  final callRef = FirebaseDatabase.instance.ref().child("calls").child(channelId);

  _callEndSubscription = callRef.onValue.listen((event) {
    final data = event.snapshot.value;
    if (data != null && data is Map<dynamic, dynamic>) {
      final status = data["status"];
      if (status == "Declined") {
        _isEnding = true;
        _callEndSubscription?.cancel();

        _stopCallTimer();
        _stopRingtone();
        agoraEngine.leaveChannel();
        navigateToBasePage();
      }
    }
  });
}

  Future<void> _fetchCallerAndReceiverDetails() async {
    String baseUrl = "${ApiUtils.baseUrl}/api";

    try {
      final callerUserRes = await http.get(Uri.parse('$baseUrl/user/${widget.callerId}'));
      if (callerUserRes.statusCode == 200 && callerUserRes.body.isNotEmpty) {
        final data = json.decode(callerUserRes.body);
        setState(() {
          callerName = "${data['firstName']} ${data['lastName']}";
          callerPhoto = data['photo'];
          callerIsCounsellor = false;
        });
      } else {
        final callerCounsellorRes = await http.get(Uri.parse('$baseUrl/counsellor/${widget.callerId}'));
        if (callerCounsellorRes.statusCode == 200 && callerCounsellorRes.body.isNotEmpty) {
          final data = json.decode(callerCounsellorRes.body);
          setState(() {
            callerName = "${data['firstName']} ${data['lastName']}";
            callerPhoto = data['photoUrl'];
            callerIsCounsellor = true;
          });
        }
      }

      final receiverUserRes = await http.get(Uri.parse('$baseUrl/user/${widget.receiverId}'));
      if (receiverUserRes.statusCode == 200 && receiverUserRes.body.isNotEmpty) {
        final data = json.decode(receiverUserRes.body);
        setState(() {
          receiverName = "${data['firstName']} ${data['lastName']}";
          receiverPhoto = data['photo'];
          receiverIsCounsellor = false;
        });
      } else {
        final receiverCounsellorRes = await http.get(Uri.parse('$baseUrl/counsellor/${widget.receiverId}'));
        if (receiverCounsellorRes.statusCode == 200 && receiverCounsellorRes.body.isNotEmpty) {
          final data = json.decode(receiverCounsellorRes.body);
          setState(() {
            receiverName = "${data['firstName']} ${data['lastName']}";
            receiverPhoto = data['photoUrl'];
            receiverIsCounsellor = true;
          });
        }
      }
    } catch (e) {
      print("❌ Error fetching caller/receiver details: $e");
    }
  }

  Future<void> _initAgora() async {
    agoraEngine = createAgoraRtcEngine();

    await agoraEngine.initialize(
      RtcEngineContext(
        appId: appId,
        channelProfile: kIsWeb
            ? ChannelProfileType.channelProfileLiveBroadcasting
            : ChannelProfileType.channelProfileCommunication,
      ),
    );

    agoraEngine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          setState(() => _joined = true);
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          _stopRingtone();
          _startCallTimer();
          _callPicked();
          _remoteUserJoined = true;
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          print("🧍 Remote user went offline (UID: $remoteUid)");

          if (_remoteUserJoined && !_isEnding) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && !_isEnding) {
                _endCall();
              }
            });
          }
        },
      ),
    );

    String? token = await AgoraService.fetchAgoraToken(widget.channelId, widget.isCaller ? 1 : 2);
    if (token != null) {
      await agoraEngine.joinChannel(
        token: token,
        channelId: widget.channelId,
        uid: widget.isCaller ? 1 : 2,
        options: const ChannelMediaOptions(
          autoSubscribeAudio: true,
          autoSubscribeVideo: false,
        ),
      );
    }
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _callTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      setState(() {
        _callDurationInSeconds++;
        final minutes = (_callDurationInSeconds ~/ 60).toString().padLeft(2, '0');
        final seconds = (_callDurationInSeconds % 60).toString().padLeft(2, '0');
        _formattedDuration = "$minutes:$seconds";
      });
    });
  }

  void _callPicked(){
    print("picking call");
    AgoraService.pickedCall(widget.channelId);
  }

  void _stopCallTimer() {
    _callTimer?.cancel();
    _callDurationInSeconds = 0;
    _formattedDuration = "00:00";
  }

  void _playRingtone() async {
    print("🔔 Starting Ringer...");
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);
    await _audioPlayer.play(AssetSource('sounds/ringtone.mp3'));

    // 🔹 Auto stop ringer after 1 minute if call is not answered
    _ringingTimer = Timer(Duration(minutes: 1), () {
      if (!_callAnswered) {
        print(
            "⏳ Call not answered. Stopping ringer and cutting the call after 1 minute.");
        _endCall();
      }
    });
  }

  void _stopRingtone() {
    if (!_callAnswered) {
      print("🔕 Stopping Ringer...");
      _callAnswered = true;
      _audioPlayer.stop();
      _ringingTimer?.cancel();
    }
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    agoraEngine.muteLocalAudioStream(_isMuted);
  }

  void _toggleSpeaker() {
    if (!kIsWeb) {
      setState(() {
        _isSpeakerOn = !_isSpeakerOn;
      });
      agoraEngine.setEnableSpeakerphone(_isSpeakerOn);
    }
  }

  Future<void> _endCall() async {
    if (_isEnding) return;

    print("end call");
    _isEnding = true;
    await AgoraService.endCall(widget.channelId);
    _stopCallTimer();
    _stopRingtone();
    FirebaseDatabase.instance.ref("agora_call_signaling").child(widget.receiverId).remove();
    agoraEngine.leaveChannel();
    navigateToBasePage();
    // final receiverUUID = await fetchReceiverUUID();
    // if (receiverUUID.isNotEmpty) {
    //   await FlutterCallkitIncoming.endCall(receiverUUID);
    // }

      final voipToken = await getVoipTokenFromUserId(widget.receiverId);
      if (voipToken != null) {
        await FirebaseNotificationService.sendCancelCallNotification(
          voipToken: voipToken,
          senderName: widget.callerId,
          channelId: widget.channelId,
          receiverId: widget.receiverId,
          callType: "audio"
        );
      }

      await FlutterCallkitIncoming.endAllCalls();
  }

//   Future<String> fetchReceiverUUID() async {
//     final firestore = FirebaseFirestore.instance;

//     try {
//       // Try from users collection
//       final userDoc = await firestore.collection('users').doc(widget.receiverId).get();
//       if (userDoc.exists && userDoc.data()?['currentCallUUID'] != null) {
//         return userDoc.data()?['currentCallUUID'];
//       }

//       // Try from counsellors collection
//       final counsellorDoc = await firestore.collection('counsellors').doc(widget.receiverId).get();
//       if (counsellorDoc.exists && counsellorDoc.data()?['currentCallUUID'] != null) {
//         return counsellorDoc.data()?['currentCallUUID'];
//       }

//       print("⚠️ No currentCallUUID found for receiver ${widget.receiverId}");
//       return ""; // Return empty string if not found
//     } catch (e) {
//       print("❌ Error fetching currentCallUUID: $e");
//       return "";
//     }
// }

Future<String> getVoipTokenFromUserId(String receiverId) async {
    final firestore = FirebaseFirestore.instance;

    try {
      // Try from users collection
      final userDoc = await firestore.collection('users').doc(widget.receiverId).get();
      if (userDoc.exists && userDoc.data()?['voipToken'] != null) {
        return userDoc.data()?['voipToken'];
      }

      // Try from counsellors collection
      final counsellorDoc = await firestore.collection('counsellors').doc(widget.receiverId).get();
      if (counsellorDoc.exists && counsellorDoc.data()?['voipToken'] != null) {
        return counsellorDoc.data()?['voipToken'];
      }

      print("⚠️ No voipToken found for receiver ${widget.receiverId}");
      return ""; // Return empty string if not found
    } catch (e) {
      print("❌ Error fetching voipToken: $e");
      return "";
    }
}


  void navigateToBasePage(){
    if(widget.isCaller){
      if(callerIsCounsellor){
        print("caller is counsellor");
        Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
                builder: (context) => CounsellorBasePage(
                      counsellorId: widget.callerId,
                      onSignOut: widget.onSignOut,
                    )
                    ),
                    (route) => false,
                    );
      }
      else{
        print("caller is user");
        Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
                builder: (context) => BasePage(
                      username: widget.callerId,
                      onSignOut: widget.onSignOut,
                    )
                    ),
                    (route) => false,
                    );
      }
    }
    else{
      if(receiverIsCounsellor){
        print("receiver is counsellor");
        Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
                builder: (context) => CounsellorBasePage(
                      counsellorId: widget.receiverId,
                      onSignOut: widget.onSignOut,
                    )
                    ),
                    (route) => false,
                    );
      }
      else{
        print("receiver is user");
        Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
                builder: (context) => BasePage(
                      username: widget.receiverId,
                      onSignOut: widget.onSignOut,
                    )
                    ),
                    (route) => false,
                    );
      }
    }
  }

  @override
  void dispose() {
    agoraEngine.leaveChannel();
    agoraEngine.release();
    _stopCallTimer();
    _stopRingtone();
    _audioPlayer.dispose();
    _ringingTimer?.cancel();
    _callEndSubscription?.cancel();
    super.dispose();
  }

@override
Widget build(BuildContext context) {
  final String displayName = widget.isCaller ? receiverName : callerName;
  final String displayPhoto = widget.isCaller ? receiverPhoto : callerPhoto;

  return Scaffold(
    backgroundColor: Colors.black87,
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 👤 Profile Picture
          CircleAvatar(
            radius: 50,
            backgroundImage: displayPhoto.isNotEmpty
                ? NetworkImage(displayPhoto)
                : const AssetImage('assets/images/default_user.png') as ImageProvider,
            backgroundColor: Colors.grey.shade800,
          ),
          const SizedBox(height: 16),

          // 📛 Name
          Text(
            displayName.isNotEmpty ? displayName : widget.isCaller ? widget.receiverId : widget.callerId,
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          // 🕑 Call Status
          Text(
            _joined
                ? "Audio Call in Progress"
                : "Connecting...",
            style: const TextStyle(color: Colors.white70, fontSize: 18),
          ),
          if (_joined)
            Text(
              _formattedDuration,
              style: const TextStyle(color: Colors.white54, fontSize: 16),
            ),

          const SizedBox(height: 40),

          // 📞 Call Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _callButton(
                icon: _isMuted ? Icons.mic_off : Icons.mic,
                label: _isMuted ? 'Unmute' : 'Mute',
                onPressed: _toggleMute,
              ),
              const SizedBox(width: 20),
              _callButton(
                icon: Icons.call_end,
                label: 'End',
                color: Colors.red,
                onPressed: _endCall,
              ),
              const SizedBox(width: 20),
              if (!kIsWeb)
                _callButton(
                  icon: _isSpeakerOn ? Icons.volume_up : Icons.hearing,
                  label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                  onPressed: _toggleSpeaker,
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

  Widget _callButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color color = Colors.white,
  }) {
    return Column(
      children: [
        CircleAvatar(
          radius: 30,
          backgroundColor: color,
          child: IconButton(
            icon: Icon(icon, color: Colors.black),
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}
