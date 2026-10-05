import 'package:foxtune_ini/foxtune_ini.dart';

import 'command_set.dart';

/// A stretch of the realtime block: [offset] up to, not including, [end].
class BlockSpan {
  const BlockSpan(this.offset, this.end);

  final int offset;
  final int end;

  int get length => end - offset;

  /// Whether the [length] bytes from [at] lie wholly within this span.
  bool covers(int at, int length) => at >= offset && at + length <= end;

  @override
  bool operator ==(Object other) =>
      other is BlockSpan && other.offset == offset && other.end == end;

  @override
  int get hashCode => Object.hash(offset, end);

  @override
  String toString() => 'BlockSpan($offset-$end)';
}

/// Which channels have been read of late, noted by every snapshot a
/// [RealtimeDecoder] given this makes - so that polling can read the parts
/// of the block they are in, and leave the rest.
///
/// A channel counts as wanted from the first time it is read until it has
/// gone unread for [keep]. One read and found not to have been polled - see
/// [missed] - is wanted from the next poll on.
class ChannelDemand {
  ChannelDemand({this.keep = const Duration(seconds: 3)});

  /// How long a channel stays wanted after it was last read.
  final Duration keep;

  /// Channels wanted whether read or not: a dashboard's, on pages not shown,
  /// so a page switched to has its readings - and its graphs their history -
  /// at once.
  Set<String> standing = const {};

  /// When each channel was last read, in [_epoch]s.
  final _readAt = <String, int>{};
  var _epoch = 0;
  var _missed = false;

  /// Notes that [name] has been read.
  void note(String name) => _readAt[name] = _epoch;

  /// Notes that [name] has been read, from a sample whose poll left it out.
  void missed(String name) {
    note(name);
    _missed = true;
  }

  /// Whether a channel has been read that the polls leave out, since this
  /// was last asked.
  bool takeMissed() {
    final missed = _missed;
    _missed = false;
    return missed;
  }

  /// Every channel wanted now, as of [now] - the time since polling began.
  ///
  /// Ages what is noted: a channel unread since [keep] before [now] is
  /// wanted no longer.
  Set<String> wanted(Duration now) {
    // An epoch per quarter second: fine enough for [keep], and noting a read
    // stays a single write.
    final epoch = now.inMilliseconds ~/ 250;
    final oldest = epoch - (keep.inMilliseconds ~/ 250);
    _epoch = epoch;
    _readAt.removeWhere((_, at) => at < oldest);
    return {...standing, ..._readAt.keys};
  }
}

/// Which parts of the realtime block a poll reads.
abstract interface class RealtimeReadPlan {
  /// The spans the next poll reads, in order; `null` reads the whole block.
  List<BlockSpan>? next();
}

/// Reads what [demand] says is wanted, and the channels those are worked out
/// from - merged into as few reads as reading the whole block would take, or
/// fewer.
///
/// The whole block is read instead while [readWholeBlock] is set, for the
/// first [warmUp] - so the first readings have everything, while what is
/// read is found out - and always where [commands] cannot ask for a part of
/// it.
class DemandReadPlan implements RealtimeReadPlan {
  DemandReadPlan({
    required this.channels,
    required this.demand,
    required EcuCommandSet commands,
    this.refresh = const Duration(milliseconds: 250),
    this.warmUp = const Duration(milliseconds: 500),
  })  : _chunk = commands.realtimeChunk,
        _canReadParts = commands.canReadRealtimeParts,
        _fields = ChannelFields(channels);

  final IniOutputChannels channels;
  final ChannelDemand demand;

  /// How often what is wanted is looked at again, where nothing read has been
  /// found missing meanwhile.
  final Duration refresh;

  /// How long the whole block is read for at first.
  final Duration warmUp;

  /// Reads the whole block, for something that needs every channel: a log,
  /// or autotuning, which must not judge a sample on a channel left unread.
  bool readWholeBlock = false;

  final int _chunk;
  final bool _canReadParts;
  final ChannelFields _fields;
  final _clock = Stopwatch();
  Duration? _plannedAt;
  List<BlockSpan>? _spans;

  @override
  List<BlockSpan>? next() {
    final size = channels.blockSize;
    if (readWholeBlock || !_canReadParts || size == null || size <= 0) {
      return null;
    }
    if (!_clock.isRunning) _clock.start();
    final now = _clock.elapsed;
    if (now < warmUp) return null;

    final plannedAt = _plannedAt;
    if (plannedAt == null ||
        demand.takeMissed() ||
        now - plannedAt >= refresh) {
      _plannedAt = now;
      _spans = planSpans(
        _fields.of(demand.wanted(now)),
        blockSize: size,
        chunk: _chunk,
      );
    }
    return _spans;
  }
}

/// The byte-backed fields a channel is worked out from: itself, where it is
/// one; what a computed channel's expression reads; and what an expression
/// it is scaled by reads - followed through, so a channel computed from
/// others computed in turn needs every field at the bottom.
class ChannelFields {
  ChannelFields(this.channels);

  final IniOutputChannels channels;
  final _closures = <String, Set<IniField>>{};

  /// The fields [names] need, together.
  Set<IniField> of(Iterable<String> names) => {
        for (final name in names) ..._closure(name, {}),
      };

  Set<IniField> _closure(String name, Set<String> visiting) {
    final known = _closures[name];
    if (known != null) return known;
    // A definition could in principle define channels in terms of each
    // other circularly; the loop is cut rather than followed.
    if (!visiting.add(name)) return const {};

    final fields = <IniField>{};
    void follow(String? source) {
      if (source == null) return;
      final compiled = CompiledExpression.tryCompile(source);
      for (final reference in compiled?.references ?? const <String>{}) {
        fields.addAll(_closure(reference, visiting));
      }
    }

    final field = channels.channelNamed(name);
    if (field != null) {
      fields.add(field);
      if (field case IniScalarField(:final scale, :final translate)) {
        if (scale case IniExpression(:final source)) follow(source);
        if (translate case IniExpression(:final source)) follow(source);
      }
    } else {
      follow(channels.computedNamed(name)?.expression);
    }
    // Names that are neither - tune constants - need nothing from the block.
    visiting.remove(name);
    return _closures[name] = fields;
  }
}

/// The spans to read for [fields], in a block of [blockSize] bytes read at
/// most [chunk] bytes a request: `null` for the whole block.
///
/// Each read costs a round trip to the ECU, so spans less than [mergeGap]
/// apart are read as one - and more are joined, nearest first, until reading
/// them takes no more requests than reading the whole block would.
List<BlockSpan>? planSpans(
  Set<IniField> fields, {
  required int blockSize,
  required int chunk,
  int mergeGap = 256,
}) {
  final ranges = [
    for (final field in fields)
      if (field.offset case final offset?
          when offset >= 0 && offset + field.type.bytes <= blockSize)
        BlockSpan(offset, offset + field.type.bytes),
  ]..sort((a, b) => a.offset - b.offset);
  // Nothing wanted: the least there is to read, so polling still shows the
  // link is alive.
  if (ranges.isEmpty) return [BlockSpan(0, blockSize < 1 ? blockSize : 1)];

  final spans = <BlockSpan>[];
  for (final range in ranges) {
    final last = spans.isEmpty ? null : spans.last;
    if (last != null && range.offset - last.end <= mergeGap) {
      if (range.end > last.end) {
        spans[spans.length - 1] = BlockSpan(last.offset, range.end);
      }
    } else {
      spans.add(range);
    }
  }

  int requests(List<BlockSpan> spans) => spans.fold(
        0,
        (sum, span) => sum + (span.length + chunk - 1) ~/ chunk,
      );
  final wholeBlock = (blockSize + chunk - 1) ~/ chunk;
  while (spans.length > 1 && requests(spans) > wholeBlock) {
    var nearest = 0;
    for (var i = 1; i < spans.length - 1; i++) {
      if (spans[i + 1].offset - spans[i].end <
          spans[nearest + 1].offset - spans[nearest].end) {
        nearest = i;
      }
    }
    spans.replaceRange(nearest, nearest + 2, [
      BlockSpan(spans[nearest].offset, spans[nearest + 1].end),
    ]);
  }

  if (spans.length == 1 && spans.single.length == blockSize) return null;
  return spans;
}
