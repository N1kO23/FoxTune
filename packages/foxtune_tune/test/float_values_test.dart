@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// Float settings, tables and channels keep their fractions.
///
/// Speeduino never stores a float, and FoxTune once read every `F32` as a
/// rounded integer. rusEFI stores hundreds of them - injector flow, fuel
/// corrections, most of its live data - so rounding would quietly turn a
/// 1.15 enrichment into 1 and a 440.37 cc/min injector into 440.
void main() {
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
      File('../foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
    ];
    doc = IniParser().parse(
      candidates.firstWhere((f) => f.existsSync()).readAsStringSync(),
    );
  });

  test('a float setting keeps its decimals', () {
    final tune = TuneState.empty(doc);
    final flow = SettingView.of(tune, 'injector_flow')!;
    expect(flow.field.type, IniDataType.f32);

    flow.setValue(440.37);
    expect(flow.value, closeTo(440.37, 1e-4));
    // The definition shows it to two places, so that is its step.
    expect(flow.step, closeTo(0.01, 1e-12));
  });

  test('a float curve keeps its decimals', () {
    final tune = TuneState.empty(doc);
    final curve = CurveView.of(tune, doc.curveNamed('cltFuelCorrCurve')!)!;

    curve.setYAt(3, 1.15);
    expect(curve.yAt(3), closeTo(1.15, 1e-6));
  });

  test('a float table keeps its decimals', () {
    final tune = TuneState.empty(doc);
    final table =
        TableView.of(tune, doc.tableNamed('postCrankingEnrichmentTbl')!)!;

    table.setValueAt(1, 2, 1.37);
    expect(table.valueAt(1, 2), closeTo(1.37, 1e-6));
  });

  test('integer storage still rounds to its step', () {
    // The VE table is U16 at 0.1 %: 55.57 has to land on 55.6.
    final tune = TuneState.empty(doc);
    final ve = TableView.of(tune, doc.tableNamed('veTableTbl')!)!;
    ve.setValueAt(0, 0, 55.57);
    expect(ve.valueAt(0, 0), closeTo(55.6, 1e-9));
  });

  test('floats survive a round trip through a .msq', () {
    final tune = TuneState.empty(doc);
    SettingView.of(tune, 'injector_flow')!.setValue(440.37);
    CurveView.of(tune, doc.curveNamed('cltFuelCorrCurve')!)!.setYAt(3, 1.15);

    final restored = TuneState.empty(doc);
    MsqCodec.decode(MsqCodec.encode(tune), restored);

    expect(
      SettingView.of(restored, 'injector_flow')!.value,
      closeTo(440.37, 1e-4),
    );
    expect(
      CurveView.of(restored, doc.curveNamed('cltFuelCorrCurve')!)!.yAt(3),
      closeTo(1.15, 1e-6),
    );
  });

  test('a float channel keeps its decimals', () {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    ByteData.sublistView(
      block,
    ).setFloat32(
        channels.channelNamed('fuelingLoad')!.offset!, 87.25, Endian.little);

    final snapshot = RealtimeDecoder(channels).decode(block);
    expect(snapshot['fuelingLoad'], 87.25);
  });
}
