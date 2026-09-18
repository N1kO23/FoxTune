import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

import '../dashboard/dashboard_screen.dart';
import '../tune/table_editor_screen.dart';
import 'connection_controller.dart';
import 'connection_state.dart';

/// The connect-and-identify screen.
///
/// This is deliberately read-only: it proves the whole stack end to end -
/// transport, envelope, CRC, handshake, definition matching - without offering
/// any way to change the tune.
class ConnectScreen extends ConsumerWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('FoxTune'),
        actions: [
          if (connection is EcuDisconnected ||
              connection is EcuConnectionFailed)
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
              onPressed: () =>
                  ref.read(connectionProvider.notifier).disconnect(),
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
          EcuConnectionFailed() => _FailedView(state: connection),
          EcuDisconnected() => const _PortList(),
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
            detail:
                'Connect a Speeduino over USB, then rescan.\n\n'
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
        Text(
          'Read-only. Tuning is not implemented yet.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => ref.read(connectionProvider.notifier).disconnect(),
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
        if (state.port case final port?)
          FilledButton.icon(
            onPressed: () =>
                ref.read(connectionProvider.notifier).connect(port),
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
          ],
        ),
      ],
    );
  }
}
