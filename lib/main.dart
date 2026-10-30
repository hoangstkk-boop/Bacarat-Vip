import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BaccaratResultCode { banker, player, tie }
enum AppUiState { loading, ready, saving, error }

class BaccaratPayoutRules {
  final double bankerWinMultiplier;
  final double playerWinMultiplier;
  final double tieWinMultiplier;
  final bool tieRefundsMainBet;

  const BaccaratPayoutRules({
    this.bankerWinMultiplier = 0.95,
    this.playerWinMultiplier = 1.0,
    this.tieWinMultiplier = 8.0,
    this.tieRefundsMainBet = true,
  });

  double netUnits({required BaccaratResultCode result, required String userBet, required int stakeUnits}) {
    final bet = userBet.trim().toUpperCase();
    if (stakeUnits < 1) throw ArgumentError.value(stakeUnits, "stakeUnits");
    if (result == BaccaratResultCode.tie) {
      return bet == "T" ? stakeUnits * tieWinMultiplier : (tieRefundsMainBet ? 0.0 : -stakeUnits.toDouble());
    }
    if (bet == result.symbol) {
      return stakeUnits * (result == BaccaratResultCode.banker ? bankerWinMultiplier : playerWinMultiplier);
    }
    return -stakeUnits.toDouble();
  }
}

class BaccaratHand {
  final String id;
  final int sequenceIndex;
  final BaccaratResultCode result;
  final String userBet;
  final int timestampMs;
  final bool isUndone;
  final int stakeUnits;

  const BaccaratHand({
    required this.id,
    required this.sequenceIndex,
    required this.result,
    required this.userBet,
    this.timestampMs = 0,
    this.isUndone = false,
    this.stakeUnits = 1,
  });

  Map<String, dynamic> toJson() => {
        "id": id,
        "seq": sequenceIndex,
        "res": result.name,
        "bet": userBet,
        "ts": timestampMs,
        "undone": isUndone,
        "stake": stakeUnits,
      };

  static BaccaratHand? tryParse(Map<String, dynamic> j) {
    try {
      final id = j["id"] as String?;
      final seq = j["seq"] as int?;
      final resStr = j["res"] as String?;
      if (id == null || seq == null || resStr == null) return null;
      final res = BaccaratResultCode.values.firstWhere((e) => e.name == resStr, orElse: () => throw FormatException());
      final rawBet = j["bet"] is String ? (j["bet"] as String).trim().toUpperCase() : res.symbol;
      final ts = j["ts"] is int ? j["ts"] as int : 0;
      final undone = j["undone"] is bool ? j["undone"] as bool : false;
      final stake = j["stake"] is int ? j["stake"] as int : 1;
      return BaccaratHand(id: id, sequenceIndex: seq, result: res, userBet: rawBet, timestampMs: ts, isUndone: undone, stakeUnits: stake);
    } catch (_) {
      return null;
    }
  }

  BaccaratHand copyWith({bool? isUndone}) => BaccaratHand(
        id: id,
        sequenceIndex: sequenceIndex,
        result: result,
        userBet: userBet,
        timestampMs: timestampMs,
        isUndone: isUndone ?? this.isUndone,
        stakeUnits: stakeUnits,
      );
}

extension BaccaratResultCodeExt on BaccaratResultCode {
  String get symbol => switch (this) {
        BaccaratResultCode.banker => "B",
        BaccaratResultCode.player => "P",
        BaccaratResultCode.tie => "T",
      };
  String get label => switch (this) {
        BaccaratResultCode.banker => "Banker",
        BaccaratResultCode.player => "Player",
        BaccaratResultCode.tie => "Tie",
      };
  Color get color => switch (this) {
        BaccaratResultCode.banker => Colors.red,
        BaccaratResultCode.player => Colors.blue,
        BaccaratResultCode.tie => Colors.amber,
      };
}

class BaccaratShoe {
  final String shoeId;
  final String tableName;
  final List<BaccaratHand> hands;
  final int shiIndex;

  const BaccaratShoe({required this.shoeId, this.tableName = "Bàn A", this.hands = const [], this.shiIndex = 100});
  List<BaccaratHand> get activeHands => hands.where((h) => !h.isUndone).toList();

  BaccaratShoe copyWith({String? shoeId, String? tableName, List<BaccaratHand>? hands, int? shiIndex}) =>
      BaccaratShoe(shoeId: shoeId ?? this.shoeId, tableName: tableName ?? this.tableName, hands: hands ?? this.hands, shiIndex: shiIndex ?? this.shiIndex);

  Map<String, dynamic> toJson() => {
        "shoeId": shoeId,
        "tableName": tableName,
        "hands": hands.map((h) => h.toJson()).toList(),
        "shi": shiIndex,
      };

  static BaccaratShoe? tryParse(Map<String, dynamic> j) {
    try {
      final sId = j["shoeId"] as String? ?? "shoe_0";
      final tName = j["tableName"] as String? ?? "Bàn A";
      final shi = j["shi"] is int ? j["shi"] as int : 100;
      final handList = (j["hands"] is List) ? j["hands"] as List : const [];
      final hands = handList.map((x) => BaccaratHand.tryParse(x)).whereType<BaccaratHand>().toList();
      return BaccaratShoe(shoeId: sId, tableName: tName, hands: hands, shiIndex: shi);
    } catch (_) {
      return null;
    }
  }
}

class NexusEngineService {
  static Map<String, dynamic> computeNexusMetrics(List<BaccaratHand> activeHands) {
    final windowed = activeHands.length > 100 ? activeHands.sublist(activeHands.length - 100) : activeHands;
    final total = windowed.length;
    
    String lifecycleStage = "Giai đoạn 1: Săn Bệt (Ván 1-25)";
    Color lifecycleColor = Colors.cyan;
    if (total > 55) {
      lifecycleStage = "Giai đoạn 3: Cuối Shoe / Nexus Risk (Ván 56+)";
      lifecycleColor = Colors.deepOrange;
    } else if (total > 25) {
      lifecycleStage = "Giai đoạn 2: Cân bằng pha (Ván 26-55)";
      lifecycleColor = Colors.amber;
    }

    if (total < 3) {
      return {
        "total": total, "shi": 100, "shiStatus": "Nexus Ready", "trafficColor": Colors.cyan,
        "bPct": 0.0, "pPct": 0.0, "tPct": 0.0,
        "bCount": 0, "pCount": 0, "tCount": 0,
        "maxStreak": 0, "currentStreak": "Chưa có",
        "nexusSuggest": "Nexus V26.1: Nạp ma trận lượng tử (>=3 tay)", "confidence": 50, "monteCarloWinRate": 50.0,
        "kellyUnits": 1, "lifecycleStage": lifecycleStage, "lifecycleColor": lifecycleColor, "suggestedBet": "Stand-Aside"
      };
    }

    int bCount = windowed.where((h) => h.result == BaccaratResultCode.banker).length;
    int pCount = windowed.where((h) => h.result == BaccaratResultCode.player).length;
    int tCount = windowed.where((h) => h.result == BaccaratResultCode.tie).length;

    double bPct = (bCount / total) * 100;
    double pPct = (pCount / total) * 100;
    double tPct = (tCount / total) * 100;

    int maxLen = 1;
    int tempLen = 1;
    int changes = 0;
    for (int i = 1; i < windowed.length; i++) {
      if (windowed[i].result != windowed[i - 1].result &&
          windowed[i].result != BaccaratResultCode.tie &&
          windowed[i - 1].result != BaccaratResultCode.tie) {
        changes++;
      }
      if (windowed[i].result == windowed[i - 1].result && windowed[i].result != BaccaratResultCode.tie) {
        tempLen++;
      } else {
        tempLen = 1;
      }
      if (tempLen > maxLen) maxLen = tempLen;
    }

    int currentStreakLen = 1;
    BaccaratResultCode? currentStreakCol;
    for (int i = windowed.length - 1; i >= 0; i--) {
      if (windowed[i].result == BaccaratResultCode.tie) continue;
      currentStreakCol = windowed[i].result;
      break;
    }
    if (currentStreakCol != null) {
      for (int i = windowed.length - 2; i >= 0; i--) {
        if (windowed[i].result == currentStreakCol) {
          currentStreakLen++;
        } else if (windowed[i].result == BaccaratResultCode.tie) {
          continue;
        } else {
          break;
        }
      }
    }
    String streakStr = currentStreakCol != null ? "${currentStreakCol.label} ($currentStreakLen tay)" : "Chưa có";

    double volatility = total > 1 ? changes / (total - 1) : 0.0;
    double entropy = - (bCount > 0 ? (bCount / total) * log(bCount / total) : 0) - (pCount > 0 ? (pCount / total) * log(pCount / total) : 0);
    int shi = ((1.0 - (volatility * 0.6 + (entropy / 0.693) * 0.4)) * 100).clamp(10, 100).toInt();

    Color trafficColor = Colors.cyan;
    String shiStatus = "Nexus ổn định";
    if (shi < 45) {
      trafficColor = Colors.deepOrange;
      shiStatus = "Biên độ hỗn loạn cao";
    } else if (shi < 70) {
      trafficColor = Colors.amber;
      shiStatus = "Pha chuyển dịch";
    }

    List<BaccaratHand> cleanHands = windowed.where((h) => h.result != BaccaratResultCode.tie).toList();
    
    double scoreB = 50.0;
    int confidence = 50;
    String suggest = "Nexus V26.1: Thị trường nhiễu - Đứng ngoài";
    String suggestedBet = "Stand-Aside";
    int kellyUnits = 0;

    if (cleanHands.length >= 4) {
      final last2 = "${cleanHands[cleanHands.length - 2].result.symbol}${cleanHands.last.result.symbol}";
      int f2B = 0, f2Total = 0;
      for (int i = 0; i < cleanHands.length - 2; i++) {
        final pattern = "${cleanHands[i].result.symbol}${cleanHands[i + 1].result.symbol}";
        if (pattern == last2) {
          f2Total++;
          if (cleanHands[i + 2].result == BaccaratResultCode.banker) f2B++;
        }
      }

      final last3 = cleanHands.length >= 5 
          ? "${cleanHands[cleanHands.length - 3].result.symbol}${cleanHands[cleanHands.length - 2].result.symbol}${cleanHands.last.result.symbol}"
          : "";
      int f3B = 0, f3Total = 0;
      if (last3.length == 3) {
        for (int i = 0; i < cleanHands.length - 3; i++) {
          final pattern = "${cleanHands[i].result.symbol}${cleanHands[i + 1].result.symbol}${cleanHands[i + 2].result.symbol}";
          if (pattern == last3) {
            f3Total++;
            if (cleanHands[i + 3].result == BaccaratResultCode.banker) f3B++;
          }
        }
      }

      double w2 = entropy > 0.5 ? 0.7 : 0.3;
      double w3 = entropy > 0.5 ? 0.3 : 0.7;

      double probB2 = f2Total > 0 ? (f2B / f2Total) * 100 : 50.0;
      double probB3 = f3Total > 0 ? (f3B / f3Total) * 100 : probB2;

      scoreB = f3Total > 0 ? (probB2 * w2 + probB3 * w3) : probB2;

      if (currentStreakLen >= 4 && currentStreakCol != null) {
        double decayFactor = (currentStreakLen - 3) * 6.0;
        if (currentStreakCol == BaccaratResultCode.banker) {
          scoreB -= decayFactor;
        } else {
          scoreB += decayFactor;
        }
      }

      confidence = scoreB >= 50 ? scoreB.round() : (100 - scoreB).round();

      final rand = Random();
      int mcWins = 0;
      int mcSims = 2000;
      bool targetIsBanker = scoreB >= 50;
      for (int s = 0; s < mcSims; s++) {
        double stochasticRoll = rand.nextDouble() * 100;
        if (stochasticRoll < confidence) {
          mcWins++;
        }
      }
      double monteCarloWinRate = (mcWins / mcSims) * 100;

      double pWin = monteCarloWinRate / 100.0;
      double odds = 0.95;
      double kellyFraction = (pWin * (odds + 1) - 1) / odds;

      if ((scoreB >= 45 && scoreB <= 55) || shi < 40 || total > 65 || kellyFraction <= 0) {
        suggest = "Nexus V26.1: Trường lực nhiễu - Đứng ngoài quan sát";
        suggestedBet = "Stand-Aside";
        confidence = 50;
        kellyUnits = 0;
      } else if (targetIsBanker) {
        suggest = "Nexus V26.1: Khuyến nghị lượng tử Banker";
        suggestedBet = "B";
        kellyUnits = (kellyFraction > 0.15 && shi >= 70) ? 3 : (kellyFraction > 0.08 ? 2 : 1);
      } else {
        suggest = "Nexus V26.1: Khuyến nghị lượng tử Player";
        suggestedBet = "P";
        kellyUnits = (kellyFraction > 0.15 && shi >= 70) ? 3 : (kellyFraction > 0.08 ? 2 : 1);
      }

      return {
        "total": total,
        "shi": shi, "shiStatus": shiStatus, "trafficColor": trafficColor,
        "bPct": bPct, "pPct": pPct, "tPct": tPct,
        "bCount": bCount, "pCount": pCount, "tCount": tCount,
        "maxStreak": maxLen, "currentStreak": streakStr,
        "nexusSuggest": suggest, "confidence": confidence,
        "monteCarloWinRate": monteCarloWinRate,
        "kellyUnits": kellyUnits,
        "lifecycleStage": lifecycleStage, "lifecycleColor": lifecycleColor,
        "suggestedBet": suggestedBet
      };
    } else {
      suggest = "Nexus V26.1: Chờ đủ vector luồng (>=4 tay)";
    }

    return {
      "total": total,
      "shi": shi, "shiStatus": shiStatus, "trafficColor": trafficColor,
      "bPct": bPct, "pPct": pPct, "tPct": tPct,
      "bCount": bCount, "pCount": pCount, "tCount": tCount,
      "maxStreak": maxLen, "currentStreak": streakStr,
      "nexusSuggest": suggest, "confidence": 50, "monteCarloWinRate": 50.0,
      "kellyUnits": 1,
      "lifecycleStage": lifecycleStage, "lifecycleColor": lifecycleColor,
      "suggestedBet": suggestedBet
    };
  }
}

class LocalStorageV26 {
  static const String kMultiPool = "multi_table_radar_pool_v26_1";

  Future<void> saveMultiPool(List<BaccaratShoe> pool, int activeIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final data = {"pool": pool.map((s) => s.toJson()).toList(), "activeIdx": activeIndex};
    await prefs.setString(kMultiPool, jsonEncode(data));
  }

  Future?> loadMultiPool() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(kMultiPool);
    if (str == null) return null;
    try {
      final jsonMap = jsonDecode(str) as Map<String, dynamic>;
      final poolRaw = jsonMap["pool"] as List;
      final pool = poolRaw.map((x) => BaccaratShoe.tryParse(x)).whereType<BaccaratShoe>().toList();
      final idx = jsonMap["activeIdx"] is int ? jsonMap["activeIdx"] as int : 0;
      return {"pool": pool, "activeIdx": idx};
    } catch (_) {
      return null;
    }
  }
}

class ZenithMainViewModel extends ChangeNotifier {
  final LocalStorageV26 storage = LocalStorageV26();
  final BaccaratPayoutRules payoutRules = const BaccaratPayoutRules();

  List<BaccaratShoe> tablePool = [
    BaccaratShoe(shoeId: "b01", tableName: "Bàn 01 (Thabet)", shiIndex: 98),
    BaccaratShoe(shoeId: "b02", tableName: "Bàn 02 (AG)", shiIndex: 55),
    BaccaratShoe(shoeId: "b03", tableName: "Bàn 03 (Evolution)", shiIndex: 92),
  ];
  int activeTableIndex = 0;

  AppUiState state = AppUiState.loading;
  double currentUnits = 0.0;
  int selectedStake = 1;

  int totalPredictions = 0;
  int correctPredictions = 0;
  String? lastSystemSuggestion; 

  int consecutiveLosses = 0;
  bool zenLockActive = false;
  int zenLockCountdown = 0;
  Timer? _zenTimer;

  double takeProfitTarget = 10.0;
  bool winLockActive = false;
  int simulatedHeartRate = 75; 
  bool bioLockActive = false; 

  bool liveStreamScanningActive = false;
  bool roiCalibrationActive = false;
  bool stealthModeActive = false;
  bool audioVoiceAlertsActive = true;
  String selectedPreset = "Thabet Standard";
  String nexusStatusText = "Nexus V26.1: Hệ thống lượng tử hoạt động ổn định.";

  BaccaratShoe get currentShoe => tablePool[activeTableIndex];

  Future<void> loadApp() async {
    state = AppUiState.loading;
    notifyListeners();
    try {
      final poolData = await storage.loadMultiPool();
      if (poolData != null) {
        tablePool = poolData["pool"] as List<BaccaratShoe>;
        activeTableIndex = poolData["activeIdx"] as int;
      }
      recalculateUnits();
      state = AppUiState.ready;
    } catch (e) {
      state = AppUiState.error;
    }
    notifyListeners();
  }

  void switchTable(int index) {
    if (index < 0 || index >= tablePool.length) return;
    activeTableIndex = index;
    HapticFeedback.selectionClick();
    recalculateUnits();
    notifyListeners();
  }

  void setStake(int stake) {
    selectedStake = stake;
    notifyListeners();
  }

  void setTakeProfitTarget(double target) {
    takeProfitTarget = target;
    notifyListeners();
  }

  void simulateHeartRateSpike(int hr) {
    simulatedHeartRate = hr;
    if (hr > 110) {
      bioLockActive = true;
      nexusStatusText = "BIOMETRIC V26.1: Nhịp tim đạt $hr BPM! Khóa sinh học kích hoạt!";
      HapticFeedback.heavyImpact();
    } else {
      bioLockActive = false;
    }
    notifyListeners();
  }

  void dismissBioLock() {
    bioLockActive = false;
    simulatedHeartRate = 75;
    nexusStatusText = "Nexus V26.1: Trạng thái sinh học đã hồi phục. Mở khóa.";
    notifyListeners();
  }

  void setPreset(String preset) {
    selectedPreset = preset;
    notifyListeners();
  }

  void toggleAudioVoiceAlerts() {
    audioVoiceAlertsActive = !audioVoiceAlertsActive;
    nexusStatusText = audioVoiceAlertsActive ? "Nexus V26.1: Âm thanh định hướng đang bật." : "Nexus V26.1: Đã tắt âm thanh.";
    notifyListeners();
  }

  void dismissWinLock() {
    winLockActive = false;
    currentUnits = 0.0;
    nexusStatusText = "Nexus V26.1: Đã khởi tạo phiên giao dịch mới.";
    notifyListeners();
  }

  void recalculateUnits() {
    double total = 0.0;
    for (var shoe in tablePool) {
      for (var h in shoe.activeHands) {
        total += payoutRules.netUnits(result: h.result, userBet: h.userBet, stakeUnits: h.stakeUnits);
      }
    }
    currentUnits = total;

    if (currentUnits >= takeProfitTarget && !winLockActive) {
      winLockActive = true;
      nexusStatusText = "WIN LOCK: Đạt mục tiêu lợi nhuận +${takeProfitTarget}U! Khóa thành quả.";
    }
  }

  String getMacroLobbySkew() {
    int totalHandsAllTables = 0;
    int totalBankerAllTables = 0;
    for (var shoe in tablePool) {
      for (var h in shoe.activeHands) {
        totalHandsAllTables++;
        if (h.result == BaccaratResultCode.banker) totalBankerAllTables++;
      }
    }
    if (totalHandsAllTables == 0) return "Macro Lobby: Cân bằng (50%)";
    double bankerSkew = (totalBankerAllTables / totalHandsAllTables) * 100;
    return "Macro Skew: Banker ${bankerSkew.toStringAsFixed(1)}% / Player ${(100 - bankerSkew).toStringAsFixed(1)}%";
  }

  Future<void> recordHand(BaccaratResultCode res, String userBet) async {
    if (zenLockActive || winLockActive || bioLockActive) return; 
    HapticFeedback.mediumImpact();

    if (lastSystemSuggestion != null && lastSystemSuggestion != "Stand-Aside" && res != BaccaratResultCode.tie) {
      totalPredictions++;
      if (lastSystemSuggestion == res.symbol) {
        correctPredictions++;
      }
    }

    final net = payoutRules.netUnits(result: res, userBet: userBet, stakeUnits: selectedStake);
    if (net < 0) {
      consecutiveLosses++;
      simulatedHeartRate += 10;
      if (simulatedHeartRate > 105) {
        bioLockActive = true;
        nexusStatusText = "BIOMETRIC V26.1: Thua liên tiếp kích hoạt Bio-Lock!";
      }

      if (consecutiveLosses >= 3) {
        zenLockActive = true;
        zenLockCountdown = 180;
        nexusStatusText = "ZEN LOCK V26.1: Thua liên tiếp 3 ván! Khóa cứng hệ thống.";
        _zenTimer?.cancel();
        _zenTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (zenLockCountdown > 0) {
            zenLockCountdown--;
            notifyListeners();
          } else {
            timer.cancel();
            zenLockActive = false;
            consecutiveLosses = 0;
            simulatedHeartRate = 75;
            nexusStatusText = "Nexus V26.1: Hết thời gian tĩnh tâm. Hệ thống mở khóa.";
            notifyListeners();
          }
        });
      }
    } else if (net > 0) {
      consecutiveLosses = 0;
      simulatedHeartRate = (simulatedHeartRate - 4).clamp(70, 120);
      nexusStatusText = "Nexus V26.1: Thắng lệnh. Duy trì nhịp độ tối ưu.";
    }

    final shoe = currentShoe;
    final seq = shoe.hands.length + 1;
    final newHand = BaccaratHand(
      id: "${DateTime.now().microsecondsSinceEpoch}",
      sequenceIndex: seq,
      result: res,
      userBet: userBet,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      stakeUnits: selectedStake,
    );

    final updatedHands = List<BaccaratHand>.from(shoe.hands)..add(newHand);
    final metrics = NexusEngineService.computeNexusMetrics(updatedHands.where((h) => !h.isUndone).toList());
    
    lastSystemSuggestion = metrics["suggestedBet"] as String?;

    tablePool[activeTableIndex] = shoe.copyWith(
      hands: updatedHands,
      shiIndex: metrics["shi"] as int,
    );

    recalculateUnits();
    await storage.saveMultiPool(tablePool, activeTableIndex);
    notifyListeners();
  }

  Future<void> undoLast() async {
    final shoe = currentShoe;
    if (shoe.hands.isEmpty) return;
    HapticFeedback.selectionClick();

    final updated = List<BaccaratHand>.from(shoe.hands);
    final lastIdx = updated.lastIndexWhere((h) => !h.isUndone);
    if (lastIdx >= 0) {
      updated[lastIdx] = updated[lastIdx].copyWith(isUndone: true);
      tablePool[activeTableIndex] = shoe.copyWith(hands: updated);
      recalculateUnits();
      await storage.saveMultiPool(tablePool, activeTableIndex);
      notifyListeners();
    }
  }

  Future<String> exportSessionCsv() async {
    final shoe = currentShoe;
    final rows = <List<String>>[["STT", "Bàn", "Kết quả", "Cược", "Đơn vị", "Lãi/Lỗ Unit"]];
    for (var h in shoe.hands) {
      final net = payoutRules.netUnits(result: h.result, userBet: h.userBet, stakeUnits: h.stakeUnits);
      rows.add([h.sequenceIndex.toString(), shoe.tableName, h.result.label, h.userBet, h.stakeUnits.toString(), net.toString()]);
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = "${dir.path}/nexus_v26_1_session_${shoe.shoeId}_${DateTime.now().millisecondsSinceEpoch}.csv";
    await File(path).writeAsString(const ListToCsvConverter().convert(rows));
    return path;
  }

  Future<void> resetCurrentTable() async {
    final shoe = currentShoe;
    tablePool[activeTableIndex] = BaccaratShoe(
      shoeId: "shoe_${DateTime.now().millisecondsSinceEpoch}",
      tableName: shoe.tableName,
      hands: [],
      shiIndex: 100,
    );
    lastSystemSuggestion = null;
    consecutiveLosses = 0;
    nexusStatusText = "Nexus V26.1: Khởi tạo bàn chơi mới.";
    recalculateUnits();
    await storage.saveMultiPool(tablePool, activeTableIndex);
    notifyListeners();
  }

  @override
  void dispose() {
    _zenTimer?.cancel();
    super.dispose();
  }
}

// --- GIAO DIỆN CHÍNH APEX V26.1 ---
class ZenithMainScreen extends StatelessWidget {
  const ZenithMainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<ZenithMainViewModel>(context);
    if (vm.state == AppUiState.loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final currentShoe = vm.currentShoe;
    final activeHands = currentShoe.activeHands;
    final metrics = NexusEngineService.computeNexusMetrics(activeHands);
    final Color trafficColor = metrics["trafficColor"];
    final Color lifecycleColor = metrics["lifecycleColor"] as Color;

    double winrate = vm.totalPredictions > 0 ? (vm.correctPredictions / vm.totalPredictions) * 100 : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: Text("Apex V26.1 Nexus [${vm.currentUnits.toStringAsFixed(2)}U]"),
        backgroundColor: vm.audioVoiceAlertsActive ? Colors.cyan[900] : Colors.blueGrey,
        actions: [
          IconButton(
            icon: const Icon(Icons.favorite, color: Colors.redAccent),
            tooltip: "Mô phỏng nhịp tim Smartwatch",
            onPressed: () {
              vm.simulateHeartRateSpike(vm.simulatedHeartRate > 105 ? 75 : 115);
            },
          ),
          IconButton(
            icon: Icon(vm.audioVoiceAlertsActive ? Icons.volume_up : Icons.volume_off),
            color: vm.audioVoiceAlertsActive ? Colors.yellowAccent : Colors.white,
            onPressed: () => vm.toggleAudioVoiceAlerts(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(border: Border.all(color: vm.audioVoiceAlertsActive ? Colors.cyan : trafficColor, width: 4)),
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: Colors.cyan[50], borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.cyan[200]!)),
                  child: Row(
                    children: [
                      const Icon(Icons.bolt, size: 18, color: Colors.cyan),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          vm.nexusStatusText,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyan),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: Colors.blueGrey[50], borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.blueGrey[200]!)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.between,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.monitor_heart, size: 16, color: Colors.red),
                          const SizedBox(width: 4),
                          Text("HR: ${vm.simulatedHeartRate} BPM", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: vm.simulatedHeartRate > 105 ? Colors.red : Colors.black87)),
                        ],
                      ),
                      Text(vm.getMacroLobbySkew(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: Colors.teal[50], borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.teal[200]!)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.between,
                    children: [
                      Text("Winrate: ${winrate.toStringAsFixed(1)}%", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.teal)),
                      Text("Monte Carlo: ${(metrics["monteCarloWinRate"] as double).toStringAsFixed(1)}%", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyan)),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 40,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: vm.tablePool.length,
                    itemBuilder: (context, idx) {
                      final table = vm.tablePool[idx];
                      final isSelected = vm.activeTableIndex == idx;
                      final isGood = table.shiIndex >= 65;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isSelected ? Colors.cyan : (isGood ? Colors.green[100] : Colors.grey[200]),
                            foregroundColor: isSelected ? Colors.black : (isGood ? Colors.green[900] : Colors.black87),
                            elevation: isSelected ? 4 : 1,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: () => vm.switchTable(idx),
                          child: Text("${table.tableName} [SHI:${table.shiIndex}%]", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: lifecycleColor.withOpacity(0.1), border: Border.all(color: lifecycleColor), borderRadius: BorderRadius.circular(6)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.between,
                    children: [
                      Text("Tiến độ: Ván thứ ${activeHands.length}/80", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                      Text(metrics["lifecycleStage"] as String, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: lifecycleColor)),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Text("Kelly Nexus: ", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.amber[100], borderRadius: BorderRadius.circular(4)),
                          child: Text("${metrics["kellyUnits"]}U", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber[950])),
                        ),
                      ],
                    ),
                    Row(
                      children: [1, 2, 5, 10].map((stake) {
                        return ChoiceChip(
                          label: Text("${stake}U", style: const TextStyle(fontSize: 11)),
                          selected: vm.selectedStake == stake,
                          onSelected: (sel) { if (sel) vm.setStake(stake); },
                        );
                      }).toList(),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 14)),
                        onPressed: () => vm.recordHand(BaccaratResultCode.banker, "B"),
                        child: Text("B - Banker (${vm.selectedStake}U)", style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, padding: const EdgeInsets.symmetric(vertical: 14)),
                        onPressed: () => vm.recordHand(BaccaratResultCode.player, "P"),
                        child: Text("P - Player (${vm.selectedStake}U)", style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.amber[800], padding: const EdgeInsets.symmetric(vertical: 14)),
                        onPressed: () => vm.recordHand(BaccaratResultCode.tie, "T"),
                        child: const Text("TIE", style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                MasterBeadPlateGrid(activeHands: activeHands),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8), border: Border.all(color: trafficColor)),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("SHI: ${metrics["shi"]}% (${metrics["shiStatus"]})", style: TextStyle(fontWeight: FontWeight.bold, color: trafficColor)),
                          Text("Chuỗi max: ${metrics["maxStreak"]} tay", style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const Divider(height: 8),
                      Text(
                        "${metrics["nexusSuggest"]} • Tin cậy: ${metrics["confidence"]}%", 
                        style: TextStyle(
                          fontSize: 12, 
                          fontWeight: FontWeight.bold, 
                          color: metrics["kellyUnits"] == 0 ? Colors.red[700] : Colors.cyan[900],
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => vm.undoLast(),
                        icon: const Icon(Icons.undo, size: 16),
                        label: const Text("Undo"),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final path = await vm.exportSessionCsv();
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Đã xuất CSV: $path")));
                        },
                        icon: const Icon(Icons.save_alt, size: 16),
                        label: const Text("CSV"),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
                        onPressed: () => vm.resetCurrentTable(),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text("Reset"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (vm.bioLockActive)
            Positioned.fill(
              child: Container(
                color: Colors.red[900]!.withOpacity(0.95),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.heart_broken, size: 64, color: Colors.yellowAccent),
                        const SizedBox(height: 16),
                        const Text("🛑 BIO-LOCK: CẢNH BÁO TÂM LÝ & NHỊP TIM", textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        Text("Phát hiện nhịp sinh học bất ổn (${vm.simulatedHeartRate} BPM)! Hệ thống cưỡng chế khóa thao tác để bảo vệ vốn.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 13)),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.yellowAccent, foregroundColor: Colors.black),
                          onPressed: () => vm.dismissBioLock(),
                          child: const Text("Tôi đã bình tâm - Mở khóa", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (vm.zenLockActive)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.9),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.lock_clock, size: 64, color: Colors.deepOrangeAccent),
                        const SizedBox(height: 16),
                        const Text("🛑 ZEN LOCK: KHÓA KỶ LUẬT TUYỆT ĐỐI", textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        const Text("Phát hiện chuỗi thua liên tiếp! Khóa cứng hệ thống trong thời gian bắt buộc.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 13)),
                        const SizedBox(height: 20),
                        Text("Thời gian nghỉ: ${vm.zenLockCountdown ~/ 60}:${(vm.zenLockCountdown % 60).toString().padLeft(2, '0')}", style: const TextStyle(color: Colors.yellowAccent, fontSize: 24, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (vm.winLockActive)
            Positioned.fill(
              child: Container(
                color: Colors.cyan[900]!.withOpacity(0.95),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.emoji_events, size: 64, color: Colors.amberAccent),
                        const SizedBox(height: 16),
                        const Text("🏆 WIN LOCK: HOÀN THÀNH MỤC TIÊU LỢI NHUẬN", textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        Text("Phiên giao dịch đã đạt +${vm.currentUnits.toStringAsFixed(1)}U. Khóa chốt lời thành công.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 13)),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.amberAccent, foregroundColor: Colors.black),
                          onPressed: () => vm.dismissWinLock(),
                          child: const Text("Đã chốt lời - Mở phiên mới", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class MasterBeadPlateGrid extends StatelessWidget {
  final List<BaccaratHand> activeHands;
  const MasterBeadPlateGrid({super.key, required this.activeHands});

  @override
  Widget build(BuildContext context) {
    if (activeHands.isEmpty) {
      return Container(
        height: 120, 
        alignment: Alignment.center, 
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey[350]!), borderRadius: BorderRadius.circular(8)),
        child: const Text("Nexus V26.1: Chờ nạp vector dữ liệu", style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    List<List<BaccaratHand>> columns = [];
    for (int i = 0; i < activeHands.length; i += 6) {
      int end = (i + 6 < activeHands.length) ? i + 6 : activeHands.length;
      columns.add(activeHands.sublist(i, end));
    }

    return Container(
      height: 120,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey[350]!), borderRadius: BorderRadius.circular(8)),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: columns.length,
        itemBuilder: (context, colIndex) {
          final colHands = columns[colIndex];
          return Container(
            width: 22,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(6, (rowIndex) {
                if (rowIndex < colHands.length) {
                  final h = colHands[rowIndex];
                  return Container(
                    width: 19,
                    height: 19,
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    decoration: BoxDecoration(color: h.result.color, shape: BoxShape.circle),
                    child: Center(
                      child: Text(h.result.symbol, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 9)),
                    ),
                  );
                } else {
                  return Container(width: 19, height: 19, margin: const EdgeInsets.symmetric(vertical: 1));
                }
              }),
            ),
          );
        },
      ),
    );
  }
}

void main() => runApp(const ZenithApp());

class ZenithApp extends StatelessWidget {
  const ZenithApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Apex V26.1 Nexus Edition",
      theme: ThemeData(primarySwatch: Colors.cyan),
      home: ChangeNotifierProvider(
        create: (_) => ZenithMainViewModel()..loadApp(),
        child: const ZenithMainScreen(),
      ),
    );
  }
}
