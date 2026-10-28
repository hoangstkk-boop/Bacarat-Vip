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
        BaccaratResultCode.banker => Colors.blue,
        BaccaratResultCode.player => Colors.red,
        BaccaratResultCode.tie => Colors.amber,
      };
}

class BaccaratShoe {
  final String shoeId;
  final String tableName;
  final List<BaccaratHand> hands;

  const BaccaratShoe({required this.shoeId, this.tableName = "Bàn A", this.hands = const []});
  List<BaccaratHand> get activeHands => hands.where((h) => !h.isUndone).toList();

  BaccaratShoe copyWith({String? shoeId, String? tableName, List<BaccaratHand>? hands}) =>
      BaccaratShoe(shoeId: shoeId ?? this.shoeId, tableName: tableName ?? this.tableName, hands: hands ?? this.hands);

  Map<String, dynamic> toJson() => {
        "shoeId": shoeId,
        "tableName": tableName,
        "hands": hands.map((h) => h.toJson()).toList(),
      };

  static BaccaratShoe? tryParse(Map<String, dynamic> j) {
    try {
      final sId = j["shoeId"] as String? ?? "shoe_0";
      final tName = j["tableName"] as String? ?? "Bàn A";
      final handList = (j["hands"] is List) ? j["hands"] as List : const [];
      final hands = handList.map((x) => BaccaratHand.tryParse(x)).whereType<BaccaratHand>().toList();
      return BaccaratShoe(shoeId: sId, tableName: tName, hands: hands);
    } catch (_) {
      return null;
    }
  }
}

// --- THUẬT TOÁN MARKOV & ENTROPY V18 ---
class ZenithMarkovAnalyticsService {
  static Map<String, dynamic> computeZenithMetrics(List<BaccaratHand> activeHands) {
    final windowed = activeHands.length > 80 ? activeHands.sublist(activeHands.length - 80) : activeHands;
    final total = windowed.length;
    if (total == 0) {
      return {
        "total": 0, "shi": 100, "shiStatus": "Sẵn sàng", "trafficColor": Colors.green,
        "bPct": 0.0, "pPct": 0.0, "tPct": 0.0,
        "bCount": 0, "pCount": 0, "tCount": 0,
        "maxStreak": 0, "currentStreak": "Chưa có",
        "markovSuggest": "Quan sát", "markovConfidence": 50, "adaptiveUnits": 1
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
      if (windowed[i].result == windowed[i - 1].result) {
        tempLen++;
      } else {
        tempLen = 1;
      }
      if (tempLen > maxLen) maxLen = tempLen;
    }

    // ĐO LƯỜNG ENTROPY & SHI
    double volatility = total > 1 ? changes / (total - 1) : 0.0;
    double entropy = - (bCount > 0 ? (bCount / total) * log(bCount / total) : 0) - (pCount > 0 ? (pCount / total) * log(pCount / total) : 0);
    int shi = ((1.0 - (volatility * 0.7 + (entropy / 0.693) * 0.3)) * 100).clamp(10, 100).toInt();

    Color trafficColor = Colors.green;
    String shiStatus = "Cầu đẹp - An toàn";
    if (shi < 45) {
      trafficColor = Colors.red;
      shiStatus = "Loạn cầu - Rủi ro cao";
    } else if (shi < 70) {
      trafficColor = Colors.orange;
      shiStatus = "Biên độ đan xen";
    }

    // MA TRẬN PHÂN TÍCH XÍCH MARKOV (MARKOV CHAIN PROBABILITY)
    String markovSuggest = "Xung đột -> Đánh 1U";
    int markovConfidence = 50;
    int adaptiveUnits = 1;

    if (windowed.length >= 3) {
      final lastTwo = "${windowed[windowed.length - 2].result.symbol}${windowed.last.result.symbol}";
      int followB = 0;
      int followP = 0;

      for (int i = 0; i < windowed.length - 2; i++) {
        final pattern = "${windowed[i].result.symbol}${windowed[i + 1].result.symbol}";
        if (pattern == lastTwo) {
          final nextRes = windowed[i + 2].result;
          if (nextRes == BaccaratResultCode.banker) followB++;
          if (nextRes == BaccaratResultCode.player) followP++;
        }
      }

      int sum = followB + followP;
      if (sum > 0) {
        double probB = (followB / sum) * 100;
        if (probB >= 60) {
          markovSuggest = "Markov: Thiên về Banker";
          markovConfidence = probB.round();
          adaptiveUnits = (shi >= 65 && markovConfidence >= 70) ? 2 : 1;
        } else if (probB <= 40) {
          markovSuggest = "Markov: Thiên về Player";
          markovConfidence = (100 - probB).round();
          adaptiveUnits = (shi >= 65 && markovConfidence >= 70) ? 2 : 1;
        }
      }
    }

    int currentLen = 1;
    String streakStr = "Chưa có";
    if (windowed.isNotEmpty) {
      final currentCol = windowed.last.result;
      for (int i = windowed.length - 2; i >= 0; i--) {
        if (windowed[i].result == currentCol) {
          currentLen++;
        } else {
          break;
        }
      }
      streakStr = "${currentCol.label} ($currentLen tay)";
    }

    return {
      "total": total,
      "shi": shi, "shiStatus": shiStatus, "trafficColor": trafficColor,
      "bPct": bPct, "pPct": pPct, "tPct": tPct,
      "bCount": bCount, "pCount": pCount, "tCount": tCount,
      "maxStreak": maxLen, "currentStreak": streakStr,
      "markovSuggest": markovSuggest, "markovConfidence": markovConfidence,
      "adaptiveUnits": adaptiveUnits
    };
  }
}

class ExportService {
  static Future<String> exportShoeCsv(BaccaratShoe shoe) async {
    final rows = <List<String>>[["STT", "Bàn", "Kết quả", "Lựa chọn", "Mức cược", "Thời gian"]];
    for (var h in shoe.hands) {
      rows.add([
        h.sequenceIndex.toString(), shoe.tableName, h.result.label, h.userBet,
        h.stakeUnits.toString(), DateTime.fromMillisecondsSinceEpoch(h.timestampMs).toLocal().toString()
      ]);
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = "${dir.path}/zenith_v18_${shoe.shoeId}_${DateTime.now().millisecondsSinceEpoch}.csv";
    await File(path).writeAsString(const ListToCsvConverter().convert(rows));
    return path;
  }
}

class LocalStorageV18 {
  static const String kMultiPool = "multi_shoe_pool_v18";
  static const String kArchives = "archives_v18";

  Future<void> saveMultiPool(List<BaccaratShoe> pool, int activeIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final data = {"pool": pool.map((s) => s.toJson()).toList(), "activeIdx": activeIndex};
    await prefs.setString(kMultiPool, jsonEncode(data));
  }

  Future<Map<String, dynamic>?> loadMultiPool() async {
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

  Future<void> archiveShoe(BaccaratShoe shoe) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(kArchives) ?? [];
    list.insert(0, jsonEncode(shoe.toJson()));
    if (list.length > 30) list.removeLast();
    await prefs.setStringList(kArchives, list);
  }

  Future<List<BaccaratShoe>> loadArchives() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(kArchives) ?? [];
    return list.map((s) => BaccaratShoe.tryParse(jsonDecode(s))).whereType<BaccaratShoe>().toList();
  }
}

class ZenithMainViewModel extends ChangeNotifier {
  final LocalStorageV18 storage = LocalStorageV18();
  final BaccaratPayoutRules payoutRules = const BaccaratPayoutRules();

  List<BaccaratShoe> tablePool = [
    BaccaratShoe(shoeId: "shoe_a_${DateTime.now().millisecondsSinceEpoch}", tableName: "Bàn A"),
    BaccaratShoe(shoeId: "shoe_b_${DateTime.now().millisecondsSinceEpoch}", tableName: "Bàn B"),
    BaccaratShoe(shoeId: "shoe_c_${DateTime.now().millisecondsSinceEpoch}", tableName: "Bàn C"),
  ];
  int activeTableIndex = 0;

  List<BaccaratShoe> archives = [];
  AppUiState state = AppUiState.loading;
  String? errorMessage;
  String? successMessage;

  int stopLossUnits = 20;
  int takeProfitUnits = 30;
  double currentUnits = 0.0;
  int selectedStake = 1;

  bool ghostModeActive = false;
  bool detoxModeActive = false;
  bool privacyCurtainActive = false;
  bool tiltWarningActive = false;
  bool pauseActive = false;
  int pauseSeconds = 60;
  Timer? _pauseTimer;

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
      archives = await storage.loadArchives();
      recalculateUnits();
      state = AppUiState.ready;
    } catch (e) {
      state = AppUiState.error;
      errorMessage = "Lỗi khởi tạo: $e";
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

  void recalculateUnits() {
    double total = 0.0;
    for (var shoe in tablePool) {
      for (var h in shoe.activeHands) {
        total += payoutRules.netUnits(result: h.result, userBet: h.userBet, stakeUnits: h.stakeUnits);
      }
    }
    currentUnits = total;

    final activeHands = currentShoe.activeHands;
    if (activeHands.length >= 3) {
      final last3 = activeHands.sublist(activeHands.length - 3);
      tiltWarningActive = last3.every((h) => h.result != BaccaratResultCode.tie && h.userBet != h.result.symbol);
    } else {
      tiltWarningActive = false;
    }

    if (currentUnits <= -stopLossUnits) detoxModeActive = true;
  }

  Future<void> recordHand(BaccaratResultCode res, String userBet) async {
    if (pauseActive || detoxModeActive || currentUnits >= takeProfitUnits) return;

    HapticFeedback.mediumImpact();
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
    tablePool[activeTableIndex] = shoe.copyWith(hands: updatedHands);

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

  Future<void> archiveCurrentShoeAndReset() async {
    final shoe = currentShoe;
    if (shoe.activeHands.isNotEmpty) {
      await storage.archiveShoe(shoe);
      archives = await storage.loadArchives();
    }
    tablePool[activeTableIndex] = BaccaratShoe(
      shoeId: "shoe_${DateTime.now().millisecondsSinceEpoch}",
      tableName: shoe.tableName,
      hands: [],
    );
    recalculateUnits();
    await storage.saveMultiPool(tablePool, activeTableIndex);
    successMessage = "Đã lưu Shoe ${shoe.tableName} và reset bàn mới!";
    notifyListeners();
  }

  void startPause() {
    _pauseTimer?.cancel();
    pauseActive = true;
    pauseSeconds = 60;
    notifyListeners();

    _pauseTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (pauseSeconds <= 1) {
        t.cancel();
        pauseActive = false;
      } else {
        pauseSeconds--;
      }
      notifyListeners();
    });
  }

  void toggleGhostMode(bool active) {
    ghostModeActive = active;
    notifyListeners();
  }

  void togglePrivacyCurtain() {
    privacyCurtainActive = !privacyCurtainActive;
    notifyListeners();
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    super.dispose();
  }
}

// --- GIAO DIỆN CHÍNH APEX V18 ---
class ZenithMainScreen extends StatelessWidget {
  const ZenithMainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<ZenithMainViewModel>(context);
    if (vm.state == AppUiState.loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (vm.ghostModeActive) return const RealFunctionalCalculatorScreen();
    if (vm.privacyCurtainActive) return PrivacyStealthScreen(onDismiss: () => vm.togglePrivacyCurtain());

    final currentShoe = vm.currentShoe;
    final activeHands = currentShoe.activeHands;
    final metrics = ZenithMarkovAnalyticsService.computeZenithMetrics(activeHands);
    final Color trafficColor = metrics["trafficColor"];

    return Scaffold(
      appBar: AppBar(
        title: Text("Apex V18 Zenith [${vm.currentUnits.toStringAsFixed(2)}U]"),
        backgroundColor: vm.currentUnits >= vm.takeProfitUnits ? Colors.amber[800] : (vm.tiltWarningActive ? Colors.deepOrange[800] : null),
        actions: [
          IconButton(icon: const Icon(Icons.calculate), onPressed: () => vm.toggleGhostMode(true)),
          IconButton(icon: const Icon(Icons.security), onPressed: () => vm.togglePrivacyCurtain()),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(border: Border.all(color: trafficColor, width: 4)),
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            // CHỌN BÀN SÂN CHƠI THABET (MULTI-TABLE RADAR)
            Row(
              children: List.generate(vm.tablePool.length, (idx) {
                final isSelected = vm.activeTableIndex == idx;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isSelected ? Colors.indigo : Colors.grey[300],
                        foregroundColor: isSelected ? Colors.white : Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: () => vm.switchTable(idx),
                      child: Text("${vm.tablePool[idx].tableName} (${vm.tablePool[idx].activeHands.length})"),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),

            // THANH CHỌN STAKE UNITS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Mức Unit: ${vm.selectedStake}U", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                Row(
                  children: [1, 2, 5, 10].map((stake) {
                    return ChoiceChip(
                      label: Text("${stake}U"),
                      selected: vm.selectedStake == stake,
                      onSelected: (sel) { if (sel) vm.setStake(stake); },
                    );
                  }).toList(),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // NÚT CƯỢC TỐC ĐỘ COMBAT 15S
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: () => vm.recordHand(BaccaratResultCode.banker, "B"),
                    child: Text("B (${vm.selectedStake}U)", style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: () => vm.recordHand(BaccaratResultCode.player, "P"),
                    child: Text("P (${vm.selectedStake}U)", style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.amber[800], padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: () => vm.recordHand(BaccaratResultCode.tie, "T"),
                    child: const Text("TIE", style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // MA TRẬN BEAD PLATE (CUỘN NGANG THẲNG MƯỢT MÀ)
            MasterBeadPlateGrid(activeHands: activeHands),
            const SizedBox(height: 6),

            // PHÂN TÍCH MARKOV & SHI
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
                  Text("${metrics["markovSuggest"]} (Gợi ý x${metrics["adaptiveUnits"]}U)", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo)),
                ],
              ),
            ),
            const Spacer(),

            // TIỆN ÍCH LƯU & PAUSE
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => vm.undoLast(),
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text("Undo 1 Ván"),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
                    onPressed: () => vm.archiveCurrentShoeAndReset(),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text("Reset Bàn Này"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Widget Lưới Lịch Sử Cuộn Ngang Thoải Mái 100+ Ván
class MasterBeadPlateGrid extends StatefulWidget {
  final List<BaccaratHand> activeHands;
  const MasterBeadPlateGrid({super.key, required this.activeHands});

  @override
  State<MasterBeadPlateGrid> createState() => _MasterBeadPlateGridState();
}

class _MasterBeadPlateGridState extends State<MasterBeadPlateGrid> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant MasterBeadPlateGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeHands.length != oldWidget.activeHands.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.activeHands.isEmpty) {
      return Container(height: 90, alignment: Alignment.center, child: const Text("Chưa có ván bài nào"));
    }
    return Container(
      height: 90,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white, 
        border: Border.all(color: Colors.grey[350]!), 
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        itemCount: widget.activeHands.length,
        itemBuilder: (context, idx) {
          final h = widget.activeHands[idx];
          return Container(
            width: 36,
            height: 36,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: h.result.color, 
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                h.result.symbol, 
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          );
        },
      ),
    );
  }
}

class RealFunctionalCalculatorScreen extends StatelessWidget {
  const RealFunctionalCalculatorScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final vm = Provider.of<ZenithMainViewModel>(context, listen: false);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("0", style: TextStyle(color: Colors.white, fontSize: 48)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => vm.toggleGhostMode(false),
                child: const Text("Thoát Ghost Mode"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PrivacyStealthScreen extends StatelessWidget {
  final VoidCallback onDismiss;
  const PrivacyStealthScreen({super.key, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Công việc cần làm"), actions: [IconButton(icon: const Icon(Icons.close), onPressed: onDismiss)]),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(children: [
          Card(child: ListTile(title: Text("• Kiểm tra báo cáo doanh thu chi nhánh"))),
          Card(child: ListTile(title: Text("• Bảo trì trang thiết bị nhà bếp B1"))),
        ]),
      ),
    );
  }
}

void main() => runApp(const ZenithApp());

class ZenithApp extends StatelessWidget {
  const ZenithApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ZenithMainViewModel()..loadApp(),
      child: MaterialApp(
        title: "Apex V18 Zenith",
        theme: ThemeData(primarySwatch: Colors.indigo),
        home: const ZenithMainScreen(),
      ),
    );
  }
}
