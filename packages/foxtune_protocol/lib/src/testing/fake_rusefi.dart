import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

import '../crc32.dart';
import 'engine_simulation.dart';
import 'fake_ts_ecu.dart';

/// A simulated rusEFI that speaks its wire protocol over TCP.
///
/// Built from a rusEFI definition, and answering as the firmware's
/// `tunerstudio.cpp` does:
///
/// * `S` returns the signature and `V` the version;
/// * `R`, `C` and `k` take the page as a little-endian word - the bytes the
///   definition's `pageIdentifier` gives, `"\x00\x01"` being page 0x0100 -
///   then offset and count, also little-endian;
/// * `B` burns a page, answering 0x04;
/// * `O` reads live data by offset and count.
///
/// Requests larger than the blocking factor are refused with a range error,
/// which is what makes a client that forgets to split rusEFI's oversized live
/// data fail here.
class FakeRusEfi extends FakeTsEcu {
  FakeRusEfi._({
    required super.signature,
    required super.version,
    required super.pageSizes,
    required super.realtimeBlockSize,
    required super.blockingFactor,
    required super.channels,
    required Map<int, int> pageNumbers,
    super.constantResolver,
  }) : _pageNumbers = pageNumbers;

  /// A rusEFI as [definition] describes it.
  factory FakeRusEfi.fromDefinition(
    IniDocument definition, {
    double? Function(String name)? constantResolver,
  }) {
    final constants = definition.constants;
    final signature = definition.identity.signature ?? 'rusEFI';
    final ids = constants.pageIdentifiers;
    return FakeRusEfi._(
      signature: signature,
      version: 'rusEFI simulated, ${signature.split(' ').last}',
      pageSizes: constants.pageSizes,
      realtimeBlockSize: definition.outputChannels.blockSize ?? 0,
      blockingFactor: constants.blockingFactor ?? 1024,
      channels: definition.outputChannels,
      constantResolver: constantResolver,
      pageNumbers: {
        for (var i = 0; i < ids.length; i++) _wordOf(ids[i]): i + 1,
      },
    );
  }

  /// Firmware page word to page number from 1.
  final Map<int, int> _pageNumbers;

  /// The little-endian word the firmware reads from an identifier's bytes.
  static int _wordOf(String identifier) {
    final bytes = [
      for (final match in RegExp(r'\\x([0-9a-fA-F]{2})').allMatches(identifier))
        int.parse(match.group(1)!, radix: 16),
    ];
    return (bytes.isEmpty ? 0 : bytes[0]) |
        (bytes.length < 2 ? 0 : bytes[1] << 8);
  }

  static int _word(Uint8List payload, int at) =>
      payload[at] | (payload[at + 1] << 8);

  @override
  void handleCommand(Socket socket, Uint8List payload) {
    switch (payload[0]) {
      case 0x53: // 'S'
        reply(socket, [0x00, ...ascii.encode(signature)]);

      case 0x56: // 'V'
        reply(socket, [0x00, ...ascii.encode(version)]);

      case 0x52: // 'R' page offset count
        final request = _pageRequest(socket, payload);
        if (request == null) return;
        final (:page, :offset, :count) = request;
        reply(socket, [
          0x00,
          ...pages[page - 1].sublist(offset, offset + count),
        ]);

      case 0x43: // 'C' page offset count data
        final request = _pageRequest(socket, payload);
        if (request == null) return;
        final (:page, :offset, :count) = request;
        if (payload.length < 7 + count) {
          reply(socket, [0x80]); // underrun
          return;
        }
        writeToPage(page, offset, payload.sublist(7, 7 + count));
        reply(socket, [0x00]);

      case 0x6B: // 'k' page offset count
        final request = _pageRequest(socket, payload, ignoreLimit: true);
        if (request == null) return;
        final (:page, :offset, :count) = request;
        replyCrc(
            socket, crc32(pages[page - 1].sublist(offset, offset + count)));

      case 0x42: // 'B' page
        if (payload.length < 3) {
          reply(socket, [0x80]);
          return;
        }
        final page = _pageNumbers[_word(payload, 1)];
        if (page == null) {
          reply(socket, [0x84]);
          return;
        }
        burn(page);
        reply(socket, [0x04]);

      case 0x4F: // 'O' offset count
        if (payload.length < 5) {
          reply(socket, [0x00, ...realtime]);
          return;
        }
        final offset = _word(payload, 1);
        final count = _word(payload, 3);
        if (count > blockingFactor || offset + count > realtime.length) {
          reply(socket, [0x84]);
          return;
        }
        reply(socket, [0x00, ...realtime.sublist(offset, offset + count)]);

      default:
        reply(socket, [0x83]);
    }
  }

  /// Page, offset and count from a page command, or `null` after replying
  /// with the error the firmware would.
  ({int page, int offset, int count})? _pageRequest(
    Socket socket,
    Uint8List payload, {
    bool ignoreLimit = false,
  }) {
    if (payload.length < 7) {
      reply(socket, [0x80]); // underrun
      return null;
    }
    final page = _pageNumbers[_word(payload, 1)];
    final offset = _word(payload, 3);
    final count = _word(payload, 5);
    if (page == null ||
        offset + count > pages[page - 1].length ||
        (!ignoreLimit && count > blockingFactor)) {
      reply(socket, [0x84]);
      return null;
    }
    return (page: page, offset: offset, count: count);
  }

  // --- The engine, in rusEFI's names ---------------------------------------

  @override
  Map<String, double> channelValues(
    EngineSimulation engine,
    EngineConditions now,
  ) {
    final sample = engine.sampleAt(now);
    final afr = sample['afr'] ?? 14.7;
    final before = engine.conditionsAt(math.max(0, now.seconds - 0.1));
    final span = now.seconds - before.seconds;
    return {
      'RPMValue': now.rpm,
      'rpmAcceleration': span <= 0 ? 0 : (now.rpm - before.rpm) / span,
      'MAPValue': now.map,
      'baroPressure': 101.3,
      'TPSValue': now.throttle,
      'coolant': now.coolant,
      'intake': now.iat,
      'VBatt': now.battery,
      'AFRValue': afr,
      'lambdaValue': afr / 14.7,
      'targetLambda': 1.0,
      'veValue': sample['VE1'] ?? 0,
      'actualLastInjection': sample['pulseWidth'] ?? 0,
      'injectorDutyCycle': sample['dutyCycle'] ?? 0,
      'sparkDwell': 3.1,
      'correctedIgnitionAdvance': sample['advance'] ?? 0,
      'fuelingLoad': now.map,
      'ignitionLoad': now.map,
      'totalFuelCorrection': 1.0,
      'seconds': now.seconds.floorToDouble(),
    };
  }

  @override
  Map<String, bool> flagValues(EngineSimulation engine, EngineConditions now) =>
      {
        'mainRelayState': true,
        'isFuelPumpOn': now.rpm > 50,
        'fan1m_state': now.coolant > 95,
        'isIdling': now.throttle < 2 && now.rpm < 1200,
        'dfcoActive': now.overrun,
        'isAboveAccelThreshold': now.throttleRate > 30,
      };
}
