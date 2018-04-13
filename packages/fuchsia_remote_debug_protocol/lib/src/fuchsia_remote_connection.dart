// Copyright 2018 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import 'common/logging.dart';
import 'common/network.dart';
import 'dart/dart_vm.dart';
import 'runners/ssh_command_runner.dart';

final String _ipv4Loopback = InternetAddress.LOOPBACK_IP_V4.address;

final String _ipv6Loopback = InternetAddress.LOOPBACK_IP_V6.address;

const ProcessManager _processManager = const LocalProcessManager();

final Logger _log = new Logger('FuchsiaRemoteConnection');

/// A function for forwarding ports on the local machine to a remote device.
///
/// Takes a remote `address`, the target device's port, and an optional
/// `interface` and `configFile`. The config file is used primarily for the
/// default SSH port forwarding configuration.
typedef Future<PortForwarder> PortForwardingFunction(
    String address, int remotePort,
    [String interface, String configFile]);

/// The function for forwarding the local machine's ports to a remote Fuchsia
/// device.
///
/// Can be overwritten in the event that a different method is required.
/// Defaults to using SSH port forwarding.
PortForwardingFunction fuchsiaPortForwardingFunction = _SshPortForwarder.start;

/// Sets [fuchsiaPortForwardingFunction] back to the default SSH port forwarding
/// implementation.
void restoreFuchsiaPortForwardingFunction() {
  fuchsiaPortForwardingFunction = _SshPortForwarder.start;
}

/// Manages a remote connection to a Fuchsia Device.
///
/// Provides affordances to observe and connect to Flutter views, isolates, and
/// perform actions on the Fuchsia device's various VM services.
///
/// Note that this class can be connected to several instances of the Fuchsia
/// device's Dart VM at any given time.
class FuchsiaRemoteConnection {
  FuchsiaRemoteConnection._(this._useIpV6Loopback, this._sshCommandRunner);

  /// Same as [FuchsiaRemoteConnection.connect] albeit with a provided
  /// [SshCommandRunner] instance.
  @visibleForTesting
  static Future<FuchsiaRemoteConnection> connectWithSshCommandRunner(
      SshCommandRunner commandRunner) async {
    final FuchsiaRemoteConnection connection = new FuchsiaRemoteConnection._(
        isIpV6Address(commandRunner.address), commandRunner);
    await connection._forwardLocalPortsToDeviceServicePorts();
    return connection;
  }

  /// Opens a connection to a Fuchsia device.
  ///
  /// Accepts an `address` to a Fuchsia device, and optionally a `sshConfigPath`
  /// in order to open the associated ssh_config for port forwarding.
  ///
  /// Will throw an [ArgumentError] if `address` is malformed.
  ///
  /// Once this function is called, the instance of [FuchsiaRemoteConnection]
  /// returned will keep all associated DartVM connections opened over the
  /// lifetime of the object.
  ///
  /// At its current state Dart VM connections will not be added or removed over
  /// the lifetime of this object.
  ///
  /// Throws an [ArgumentError] if the supplied `address` is not valid IPv6 or
  /// IPv4.
  ///
  /// Note that if `address` is ipv6 link local (usually starts with fe80::),
  /// then `interface` will probably need to be set in order to connect
  /// successfully (that being the outgoing interface of your machine, not the
  /// interface on the target machine).
  static Future<FuchsiaRemoteConnection> connect(
    String address, [
    String interface = '',
    String sshConfigPath,
  ]) async {
    return await FuchsiaRemoteConnection.connectWithSshCommandRunner(
      new SshCommandRunner(
        address: address,
        interface: interface,
        sshConfigPath: sshConfigPath,
      ),
    );
  }

  final List<PortForwarder> _forwardedVmServicePorts = <PortForwarder>[];
  final SshCommandRunner _sshCommandRunner;
  final bool _useIpV6Loopback;

  /// VM service cache to avoid repeating handshakes across function
  /// calls. Keys a forwarded port to a DartVm connection instance.
  final Map<int, DartVm> _dartVmCache = <int, DartVm>{};

  /// Closes all open connections.
  ///
  /// Any objects that this class returns (including any child objects from
  /// those objects) will subsequently have its connection closed as well, so
  /// behavior for them will be undefined.
  Future<Null> stop() async {
    for (PortForwarder fp in _forwardedVmServicePorts) {
      // Closes VM service first to ensure that the connection is closed cleanly
      // on the target before shutting down the forwarding itself.
      final DartVm vmService = _dartVmCache[fp.port];
      _dartVmCache[fp.port] = null;
      await vmService?.stop();
      await fp.stop();
    }
    _dartVmCache.clear();
    _forwardedVmServicePorts.clear();
  }

  /// Returns a list of [FlutterView] objects.
  ///
  /// This is run across all connected DartVM connections that this class is
  /// managing.
  Future<List<FlutterView>> getFlutterViews() async {
    final List<FlutterView> views = <FlutterView>[];
    if (_forwardedVmServicePorts.isEmpty) {
      return views;
    }
    for (PortForwarder fp in _forwardedVmServicePorts) {
      final DartVm vmService = await _getDartVm(fp.port);
      views.addAll(await vmService.getAllFlutterViews());
    }
    return new List<FlutterView>.unmodifiable(views);
  }

  /// TODO: Document me!
  ///
  /// Returns a main isolate whose name matches the pattern supplied.
  /// This Isolate can pop up in any VM.
  ///
  /// Note that in its current state this is not capable of listening for an
  /// application to start up.
  ///
  /// In most cases when a mod starts up it runs inside its own instance of the
  /// Dart VM.
  Future<List<IsolateRef>> getMainIsolatesByPattern(Pattern pattern) async {
    if (_forwardedVmServicePorts.isEmpty) {
      return null;
    }
    List<Future<List<IsolateRef>>> isolates = <Future<List<IsolateRef>>>[];
    for (PortForwarder fp in _forwardedVmServicePorts) {
      final DartVm vmService = await _getDartVm(fp.port);
      isolates.add(vmService.getIsolatesByPattern(pattern));
    }
    return Future.wait(isolates).then((listOfLists) {
      List<List<IsolateRef>> mutableListOfLists = new List.from(listOfLists)
        ..retainWhere((list) => !list.isEmpty);
      return mutableListOfLists.fold<List<IsolateRef>>(
        <IsolateRef>[],
        (prevValue, element) {
          prevValue.addAll(element);
          return prevValue;
        },
      );
    });
  }

  Future<DartVm> _getDartVm(int port) async {
    if (!_dartVmCache.containsKey(port)) {
      // While the IPv4 loopback can be used for the initial port forwarding
      // (see [PortForwarder.start]), the address is actually bound to the IPv6
      // loopback device, so connecting to the IPv4 loopback would fail when the
      // target address is IPv6 link-local.
      final String addr = _useIpV6Loopback
          ? 'http://\[$_ipv6Loopback\]:$port'
          : 'http://$_ipv4Loopback:$port';
      final Uri uri = Uri.parse(addr);
      final DartVm dartVm = await DartVm.connect(uri);
      _dartVmCache[port] = dartVm;
    }
    return _dartVmCache[port];
  }

  /// Forwards a series of local device ports to the remote device.
  ///
  /// When this function is run, all existing forwarded ports and connections
  /// are reset by way of [stop].
  Future<Null> _forwardLocalPortsToDeviceServicePorts() async {
    await stop();
    final List<int> servicePorts = await getDeviceServicePorts();
    _forwardedVmServicePorts
        .addAll(await Future.wait(servicePorts.map((int deviceServicePort) {
      return fuchsiaPortForwardingFunction(
          _sshCommandRunner.address,
          deviceServicePort,
          _sshCommandRunner.interface,
          _sshCommandRunner.sshConfigPath);
    })));
  }

  /// Gets the open Dart VM service ports on a remote Fuchsia device.
  ///
  /// The method attempts to get service ports through an SSH connection. Upon
  /// successfully getting the VM service ports, returns them as a list of
  /// integers. If an empty list is returned, then no Dart VM instances could be
  /// found. An exception is thrown in the event of an actual error when
  /// attempting to acquire the ports.
  Future<List<int>> getDeviceServicePorts() async {
    // TODO(awdavies): This is using a temporary workaround rather than a
    // well-defined service, and will be deprecated in the near future.
    final List<String> lsOutput =
        await _sshCommandRunner.run('ls /tmp/dart.services');
    final List<int> ports = <int>[];

    // The output of lsOutput is a list of available ports as the Fuchsia dart
    // service advertises. An example lsOutput would look like:
    //
    // [ '31782\n', '1234\n', '11967' ]
    for (String s in lsOutput) {
      final String trimmed = s.trim();
      final int lastSpace = trimmed.lastIndexOf(' ');
      final String lastWord = trimmed.substring(lastSpace + 1);
      if ((lastWord != '.') && (lastWord != '..')) {
        final int value = int.parse(lastWord, onError: (_) => null);
        if (value != null) {
          ports.add(value);
        }
      }
    }
    return ports;
  }
}

/// Defines an interface for port forwarding.
///
/// When a port forwarder is initialized, it is intended to save a port through
/// which a connection is persisted along the lifetime of this object.
///
/// To shut down a port forwarder you must call the [stop] function.
abstract class PortForwarder {
  /// Determines the port which is being forwarded from the local machine.
  int get port;

  /// The destination port on the other end of the port forwarding tunnel.
  int get remotePort;

  /// Shuts down and cleans up port forwarding.
  Future<Null> stop();
}

/// Instances of this class represent a running SSH tunnel.
///
/// The SSH tunnel is from the host to a VM service running on a Fuchsia device.
class _SshPortForwarder implements PortForwarder {
  _SshPortForwarder._(
    this._remoteAddress,
    this._remotePort,
    this._localSocket,
    this._process,
    this._interface,
    this._sshConfigPath,
    this._ipV6,
  );

  final String _remoteAddress;
  final int _remotePort;
  final ServerSocket _localSocket;
  final Process _process;
  final String _sshConfigPath;
  final String _interface;
  final bool _ipV6;

  @override
  int get port => _localSocket.port;

  @override
  int get remotePort => _remotePort;

  /// Starts SSH forwarding through a subprocess, and returns an instance of
  /// [_SshPortForwarder].
  static Future<_SshPortForwarder> start(String address, int remotePort,
      [String interface, String sshConfigPath]) async {
    final bool isIpV6 = isIpV6Address(address);
    final ServerSocket localSocket = await _createLocalSocket();
    if (localSocket == null || localSocket.port == 0) {
      _log.warning('_SshPortForwarder failed to find a local port for '
          '$address:$remotePort');
      return null;
    }
    // TODO(awdavies): The square-bracket enclosure for using the IPv6 loopback
    // didn't appear to work, but when assigning to the IPv4 loopback device,
    // netstat shows that the local port is actually being used on the IPv6
    // loopback (::1). While this can be used for forwarding to the destination
    // IPv6 interface, it cannot be used to connect to a websocket.
    final String formattedForwardingUrl =
        '${localSocket.port}:$_ipv4Loopback:$remotePort';
    final List<String> command = <String>['ssh'];
    if (isIpV6) {
      command.add('-6');
    }
    if (sshConfigPath != null) {
      command.addAll(<String>['-F', sshConfigPath]);
    }
    final String targetAddress =
        isIpV6 && interface.isNotEmpty ? '$address%$interface' : address;
    command.addAll(<String>[
      '-nNT',
      '-L',
      formattedForwardingUrl,
      targetAddress,
    ]);
    _log.fine("_SshPortForwarder running '${command.join(' ')}'");
    final Process process = await _processManager.start(command);
    process.exitCode.then((int c) {
      _log.fine("'${command.join(' ')}' exited with exit code $c");
    });
    _log.fine(
        'Set up forwarding from ${localSocket.port} to $address port $remotePort');
    return new _SshPortForwarder._(address, remotePort, localSocket, process,
        interface, sshConfigPath, isIpV6);
  }

  /// Kills the SSH forwarding command, then to ensure no ports are forwarded,
  /// runs the SSH 'cancel' command to shut down port forwarding completely.
  @override
  Future<Null> stop() async {
    // Kill the original SSH process if it is still around.
    _process.kill();
    // Cancel the forwarding request. See [start] for commentary about why this
    // uses the IPv4 loopback.
    final String formattedForwardingUrl =
        '${_localSocket.port}:$_ipv4Loopback:$_remotePort';
    final List<String> command = <String>['ssh'];
    final String targetAddress = _ipV6 && _interface.isNotEmpty
        ? '$_remoteAddress%$_interface'
        : _remoteAddress;
    if (_sshConfigPath != null) {
      command.addAll(<String>['-F', _sshConfigPath]);
    }
    command.addAll(<String>[
      '-O',
      'cancel',
      '-L',
      formattedForwardingUrl,
      targetAddress,
    ]);
    _log.fine(
        'Shutting down SSH forwarding with command: ${command.join(' ')}');
    final ProcessResult result = await _processManager.run(command);
    if (result.exitCode != 0) {
      _log.warning(
          'Command failed:\nstdout: ${result.stdout}\nstderr: ${result.stderr}');
    }
    _localSocket.close();
  }

  /// Attempts to find an available port.
  ///
  /// If successful returns a valid [ServerSocket] (which must be disconnected
  /// later).
  static Future<ServerSocket> _createLocalSocket() async {
    ServerSocket s;
    try {
      s = await ServerSocket.bind(_ipv4Loopback, 0);
    } catch (e) {
      // Failures are signaled by a return value of 0 from this function.
      _log.warning('_createLocalSocket failed: $e');
      return null;
    }
    return s;
  }
}
