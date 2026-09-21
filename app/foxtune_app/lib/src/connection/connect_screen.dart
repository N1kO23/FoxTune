import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

import '../autotune/autotune_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../dashboard/gauge_status.dart';
import '../settings/settings_screen.dart';
import '../tune/msq_actions.dart';
import '../tune/recovered_edits.dart';
import '../tune/table_editor_screen.dart';
import '../tune/tune_controller.dart';
import 'connection_controller.dart';
import 'connection_state.dart';
import 'connection_watchdog.dart';

/// The app shell: pick a port, connect, then hand off to the dashboard and
/// table editor.
///
/// Connecting alone changes nothing on the ECU. Editing requires a signature
/// match and an explicit write-mode opt-in, and nothing is committed until a
/// burn - see [WritePermission].
class ConnectScreen extends ConsumerWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    // Both live as long as the app: one notices a connection ending, the
    // other keeps the screen on while there is one.
    ref.watch(connectionWatchdogProvider);
    ref.watch(screenWakeWatcherProvider);
    ref.watch(unburnedEditsGuardProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('FoxTune'),
        actions: [
          if (connection is EcuDisconnected ||
              connection is EcuConnectionFailed ||
              connection is EcuConnectionLost)
            IconButton(
              tooltip: 'Rescan ports',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(portsProvider),
            ),
          if (connection is EcuConnected) ...[
            IconButton(
              tooltip: 'Connection details',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (_) => _ConnectedView(state: connection),
              ),
            ),
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(Icons.link_off),
              onPressed: () => confirmDisconnect(context, ref),
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: switch (connection) {
          EcuConnecting(:final port) => _Busy(
            message:
                'FOX1: Commencing operation. Connecting to ${port.label}...',
          ),
          EcuConnected() => _ConnectedShell(connection: connection),
          EcuConnectionFailed() => _WithRecoveredEdits(
            child: _FailedView(state: connection),
          ),
          EcuConnectionLost() => _WithRecoveredEdits(
            child: _LostView(state: connection),
          ),
          EcuDisconnected() => const _WithRecoveredEdits(child: _PortList()),
        },
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _PortList extends ConsumerWidget {
  const _PortList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ports = ref.watch(portsProvider);

    return ports.when(
      loading: () => const _Busy(message: 'Scanning for serial ports...'),
      error: (error, _) => _Message(
        icon: Icons.usb_off,
        title: 'Cannot list serial ports',
        detail: error.toString(),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _Message(
            icon: Icons.usb_off,
            title: 'No serial ports found',
            detail: Platform.isAndroid
                ? 'Plug the Speeduino in with a USB OTG cable. It appears '
                      'here on its own - and if Android offers to open '
                      'FoxTune, tick "always" so it stops asking for '
                      'permission.'
                : 'Connect a Speeduino over USB, then rescan.\n\n'
                      'On Linux you may need to be in the dialout group:\n'
                      'sudo usermod -aG dialout \$USER',
            action: Column(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => ref.invalidate(portsProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rescan'),
                ),
                const SizedBox(height: 8),
                const _NetworkTile(),
              ],
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length + 1,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index == list.length) return const _NetworkTile();
            final port = list[index];
            return ListTile(
              leading: Icon(port.isLikelyEcu ? Icons.memory : Icons.usb),
              title: Text(port.address),
              subtitle: Text(_subtitleFor(port)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => ref.read(connectionProvider.notifier).connect(port),
            );
          },
        );
      },
    );
  }

  static String _subtitleFor(EcuPort port) {
    final parts = <String>[
      if (port.description?.isNotEmpty ?? false) port.description!,
      if (port.manufacturer?.isNotEmpty ?? false) port.manufacturer!,
      if (port.vendorId != null && port.productId != null)
        '${_hex(port.vendorId!)}:${_hex(port.productId!)}',
    ];
    return parts.isEmpty ? 'Unknown device' : parts.join(' · ');
  }

  static String _hex(int value) =>
      value.toRadixString(16).padLeft(4, '0').toUpperCase();
}

class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.state});
  final EcuConnected state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final definition = state.definition;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SignatureCard(state: state),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              _Row(label: 'Port', value: state.port.address),
              _Row(label: 'Signature', value: state.identification.signature),
              _Row(label: 'Version', value: state.identification.version),
              if (definition != null) ...[
                _Row(
                  label: 'Pages',
                  value:
                      '${definition.constants.pageCount} '
                      '(${definition.constants.pageSizes.fold<int>(0, (a, b) => a + b)} bytes)',
                ),
                _Row(
                  label: 'Blocking factor',
                  value:
                      '${definition.constants.blockingFactor ?? "unknown"} bytes',
                ),
                _Row(
                  label: 'Realtime block',
                  value:
                      '${definition.outputChannels.blockSize ?? 0} bytes, '
                      '${definition.outputChannels.channels.length} channels',
                ),
                _Row(
                  label: 'Tables / curves',
                  value:
                      '${definition.tables.length} / '
                      '${definition.curves.length}',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        Builder(
          builder: (context) {
            final permission = ref.watch(writePermissionProvider);
            return Text(
              permission.allowed
                  ? 'Write mode is on. Changes are verified against the '
                        "ECU's own CRC before anything is burned."
                  // Be specific: a signature mismatch reads very differently
                  // from write mode simply being off.
                  : permission.reason ?? 'Read-only.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            );
          },
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            // Ask over the sheet, and close it only once actually
            // disconnected - closing first would leave the question with no
            // screen to be asked on.
            final navigator = Navigator.of(context);
            if (await confirmDisconnect(context, ref)) navigator.pop();
          },
          icon: const Icon(Icons.link_off),
          label: const Text('Disconnect'),
        ),
      ],
    );
  }
}

class _SignatureCard extends StatelessWidget {
  const _SignatureCard({required this.state});
  final EcuConnected state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (
      IconData icon,
      Color color,
      String title,
      String detail,
    ) = switch (state.signatureStatus) {
      SignatureStatus.matched => (
        Icons.verified,
        scheme.primary,
        'Definition matches',
        'The loaded definition describes this firmware, so page offsets '
            'can be trusted.',
      ),
      SignatureStatus.mismatched => (
        Icons.warning_amber,
        scheme.error,
        'Definition mismatch',
        'This ECU reports "${state.identification.signature}" but the loaded '
            'definition is for "${state.expectedSignature}". Offsets may be '
            'wrong, so writing stays disabled.',
      ),
      SignatureStatus.unknown => (
        Icons.help_outline,
        scheme.outline,
        'No definition loaded',
        'Without a definition the page layout is unknown.',
      ),
    };

    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(detail, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks before disconnecting over edits that were never burned.
///
/// The edits are kept either way - they can be saved as a `.msq` from the
/// connect screen - but a tuner who meant to burn first deserves the chance.
///
/// Returns whether it disconnected.
Future<bool> confirmDisconnect(BuildContext context, WidgetRef ref) async {
  final tune = ref.read(tuneProvider).valueOrNull;
  if (tune != null && tune.isDirty) {
    final pages = tune.dirtyPages.length;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: StatusPalette.warning),
        title: const Text('Disconnect with unburned changes?'),
        content: Text(
          '$pages page(s) have changes that have not been burned to the ECU. '
          'They will be kept so you can save them as a .msq, but the ECU will '
          'not have them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (proceed != true) return false;
  }
  await ref.read(connectionProvider.notifier).disconnect();
  return true;
}

/// A connection that was working, and stopped.
class _LostView extends ConsumerWidget {
  const _LostView({required this.state});
  final EcuConnectionLost state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Message(
    icon: Icons.link_off,
    title: 'Connection lost',
    detail: '${state.reason}\n\n${state.port.label}',
    action: Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: () => ref.read(connectionProvider.notifier).reconnect(),
          icon: const Icon(Icons.refresh),
          label: const Text('Reconnect'),
        ),
        OutlinedButton(
          onPressed: () => ref.read(connectionProvider.notifier).disconnect(),
          child: const Text('Back to ports'),
        ),
      ],
    ),
  );
}

/// Puts rescued edits in front of the user until they are dealt with.
class _WithRecoveredEdits extends ConsumerWidget {
  const _WithRecoveredEdits({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recovered = ref.watch(recoveredEditsProvider);
    if (recovered == null) return child;

    final theme = Theme.of(context);
    return Column(
      children: [
        Material(
          color: StatusPalette.warning.withValues(alpha: 0.14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_note, color: StatusPalette.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Unburned changes to ${recovered.pages.length} '
                        'page(s) were kept when the connection ended.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        final saved = await MsqActions.save(
                          context,
                          ref,
                          recovered.tune,
                        );
                        if (saved) {
                          ref.read(recoveredEditsProvider.notifier).state =
                              null;
                        }
                      },
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Save as .msq'),
                    ),
                    TextButton(
                      onPressed: () =>
                          ref.read(recoveredEditsProvider.notifier).state =
                              null,
                      child: const Text('Discard'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _FailedView extends ConsumerWidget {
  const _FailedView({required this.state});
  final EcuConnectionFailed state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Message(
    icon: Icons.error_outline,
    title: 'Could not connect',
    detail: state.message,
    action: Wrap(
      spacing: 12,
      children: [
        if (state.port != null)
          FilledButton.icon(
            // Through reconnect(), so a network ECU is retried over TCP
            // rather than handed to the USB transport by address.
            onPressed: () => ref.read(connectionProvider.notifier).reconnect(),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        OutlinedButton(
          onPressed: () => ref.read(connectionProvider.notifier).disconnect(),
          child: const Text('Back to ports'),
        ),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: theme.textTheme.labelLarge),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// Entry point for a Speeduino reached over WiFi rather than a cable.
class _NetworkTile extends ConsumerWidget {
  const _NetworkTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: const Icon(Icons.wifi),
    title: const Text('Network ECU'),
    subtitle: const Text('ESP8266/ESP32 WiFi bridge over TCP'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      final address = await showDialog<String>(
        context: context,
        builder: (_) => const _AddressDialog(),
      );
      if (address == null || address.isEmpty) return;
      await ref.read(connectionProvider.notifier).connectToNetwork(address);
    },
  );
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _controller = TextEditingController(text: '192.168.4.1:2000');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect to network ECU'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(
        labelText: 'Address',
        helperText: 'host or host:port (default port 2000)',
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Connect')),
    ],
  );
}

/// Dashboard and table editor, once connected.
class _ConnectedShell extends StatefulWidget {
  const _ConnectedShell({required this.connection});

  final EcuConnected connection;

  @override
  State<_ConnectedShell> createState() => _ConnectedShellState();
}

class _ConnectedShellState extends State<_ConnectedShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(connection: widget.connection),
      TableEditorScreen(connection: widget.connection),
      SettingsScreen(connection: widget.connection),
      AutotuneScreen(connection: widget.connection),
    ];

    return Column(
      children: [
        Expanded(
          // Kept alive so switching tabs does not restart polling or discard
          // an in-progress edit.
          child: IndexedStack(index: _index, children: pages),
        ),
        NavigationBar(
          selectedIndex: _index,
          height: 60,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.speed_outlined),
              selectedIcon: Icon(Icons.speed),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.grid_on_outlined),
              selectedIcon: Icon(Icons.grid_on),
              label: 'Tables',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'Settings',
            ),
            NavigationDestination(
              icon: Icon(Icons.auto_graph_outlined),
              selectedIcon: Icon(Icons.auto_graph),
              label: 'Autotune',
            ),
          ],
        ),
      ],
    );
  }
}
