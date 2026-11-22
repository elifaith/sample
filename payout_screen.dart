import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'money.dart';
import 'auth_api.dart';
import '../utils/receipt_delivery.dart';
import '../widgets/auth_components.dart';
import '../widgets/withdrawal_receipt_dialog.dart';

class PayoutScreen extends StatefulWidget {
  const PayoutScreen({
    super.key,
    required this.api,
    required this.token,
    this.walletId,
  });

  final AuthApi api;
  final String token;
  final int? walletId;

  @override
  State<PayoutScreen> createState() => _PayoutScreenState();
}

class _PayoutScreenState extends State<PayoutScreen> {
  final _amount = TextEditingController();
  final Map<String, TextEditingController> _details = {};
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  List<Map<String, dynamic>> _wallets = const [];
  List<Map<String, dynamic>> _options = const [];
  List<Map<String, dynamic>> _requests = const [];
  Map<String, dynamic>? _wallet;
  Map<String, dynamic>? _option;
  bool _securityPinSet = false;
  Map<String, dynamic> _packagePlan = const {};
  Map<String, dynamic> _subscriptionContext = const {};
  Map<String, dynamic> _savedPayoutProfile = const {};
  String _preferredCurrency = 'USD';

  List<String> get _fields => (_option?['fields'] as List? ?? const [])
      .map((field) => field.toString())
      .toList();
  String get _currency => _wallet?['currency']?.toString() ?? 'USD';
  double? get _packageMinimumMajorInWallet {
    final minor = (_packagePlan['minimum_withdrawal_minor'] as num?)?.toDouble() ?? 0;
    if (minor <= 0) return 0;
    final source = _packagePlan['currency']?.toString().toUpperCase() ?? _currency;
    final precision = (_packagePlan['currency_minor_units'] as num?)?.toInt() ??
        currencyPrecision(source);
    return widget.api.convertMajor(minor / math.pow(10, precision), source, _currency);
  }

  double? get _methodMinimumMajorInWallet {
    final minimum = double.tryParse(_option?['min_withdrawal']?.toString() ?? '') ?? 0;
    if (minimum <= 0) return 0;
    final source = _option?['currency']?.toString().toUpperCase() ?? 'USD';
    return widget.api.convertMajor(minimum, source, _currency);
  }

  double get _minimumMajor => math.max(
    _methodMinimumMajorInWallet ?? 0,
    _packageMinimumMajorInWallet ?? 0,
  ).toDouble();
  int get _digits => currencyPrecision(_currency);
  double get _availableMajor =>
      ((_wallet?['available_balance_minor'] as num?)?.toDouble() ?? 0) /
      math.pow(10, _digits);
  TextEditingController _detailController(String field) => _details.putIfAbsent(
    '${_option?['id']}:$field', () => TextEditingController(),
  );

  Map<String, dynamic> _planForWallet(Map<String, dynamic>? wallet,
      Map<String, dynamic> context) {
    final group = switch (wallet?['type']?.toString()) {
      'share' => 'group_a',
      'review_group_c' => 'group_c',
      'review_group_b' || 'review' => 'group_b',
      _ => null,
    };
    final subscriptions = (context['active_marketplaces'] as List? ?? const [])
        .whereType<Map>().toList();
    final subscription = group == null
        ? subscriptions.firstOrNull
        : subscriptions.where((item) => item['group_key'] == group).firstOrNull;
    final planId = subscription?['subscription_plan_id']?.toString();
    final catalog = context['catalog'];
    if (planId == null || catalog is! Map) return const {};
    for (final group in (catalog['subscription_groups'] as List? ?? const []).whereType<Map>()) {
      for (final plan in (group['plans'] as List? ?? const []).whereType<Map>()) {
        if (plan['id']?.toString() == planId) return Map<String, dynamic>.from(plan);
      }
    }
    return const {};
  }

  double get _enteredAmount =>
      double.tryParse(_amount.text.trim().replaceAll(',', '')) ?? 0;
  double get _feeRate =>
      double.tryParse(_option?['tax']?.toString() ?? '') ?? 0;
  double get _fee => _enteredAmount > 0 ? _enteredAmount * _feeRate / 100 : 0;

  @override
  void initState() {
    super.initState();
    _amount.addListener(_amountChanged);
    _load();
  }

  void _amountChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _amount.removeListener(_amountChanged);
    _amount.dispose();
    for (final controller in _details.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await widget.api.loadExchangeRates(widget.token);
      final results = await Future.wait([
        widget.api.get('wallets', widget.token),
        widget.api.get('withdrawal-options', widget.token),
        widget.api.get('withdrawals', widget.token),
        widget.api.get('me', widget.token),
      ]);

      List<Map<String, dynamic>> list(dynamic data) {
        final rows = data is Map<String, dynamic> ? data['data'] : data;
        return rows is List
            ? rows.whereType<Map<String, dynamic>>().toList()
            : const [];
      }

      final wallets = list(results[0]['data'])
          .where(
            (w) =>
                w['type'] != 'topup_fund' &&
                w['withdrawal_enabled'] != false &&
                (widget.walletId == null ||
                    (w['id'] as num?)?.toInt() == widget.walletId),
          )
          .toList();
      final options =
          list(results[1]['data'])
              .where((o) => o['is_available'] != false)
              .toList()
            ..sort(
              (a, b) => ((a['order'] as num?)?.toInt() ?? 999).compareTo(
                (b['order'] as num?)?.toInt() ?? 999,
              ),
            );
      final requests = list(results[2]['data']);
      final user = results[3]['data'];
      final payoutProfile =
          user is Map<String, dynamic> && user['payout_profile'] is Map
          ? Map<String, dynamic>.from(user['payout_profile'] as Map)
          : <String, dynamic>{};
      final savedDetails = payoutProfile['details'] is Map
          ? Map<String, dynamic>.from(payoutProfile['details'] as Map)
          : <String, dynamic>{};
      final savedOptionId = int.tryParse(
        payoutProfile['withdrawal_option_id']?.toString() ?? '',
      );
      Map<String, dynamic> asMap(dynamic value) => value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      final subscriptionContext = user is Map<String, dynamic>
          ? asMap(user['subscription_context'])
          : <String, dynamic>{};
      final selectedWallet = wallets
              .where((w) => (w['id'] as num?)?.toInt() ==
                  ((_wallet?['id'] as num?)?.toInt() ?? widget.walletId))
              .firstOrNull ?? wallets.firstOrNull;
      final packagePlan = _planForWallet(selectedWallet, subscriptionContext);
      if (!mounted) return;
      setState(() {
        _preferredCurrency = user is Map<String, dynamic>
            ? (user['preferred_currency']?.toString() ??
                  widget.api.preferredCurrency)
            : widget.api.preferredCurrency;
        widget.api.setPreferredCurrency(_preferredCurrency);
        _wallets = wallets;
        _options = options;
        _requests = requests;
        _securityPinSet =
            user is Map<String, dynamic> && user['security_pin_set'] == true;
        _savedPayoutProfile =
            user is Map<String, dynamic> && user['payout_profile'] is Map
            ? Map<String, dynamic>.from(user['payout_profile'] as Map)
            : const {};
        _subscriptionContext = subscriptionContext;
        _packagePlan = packagePlan;
        _wallet = selectedWallet;
        final oldOptionId = (_option?['id'] as num?)?.toInt();
        _option =
            options
                .where(
                  (o) =>
                      (o['id'] as num?)?.toInt() ==
                      (oldOptionId ?? savedOptionId),
                )
                .firstOrNull ??
            options.firstOrNull;
        for (final entry in savedDetails.entries) {
          final key = '$savedOptionId:${entry.key}';
          _details.putIfAbsent(key, () => TextEditingController()).text =
              entry.value?.toString() ?? '';
        }
        _loading = false;
      });
      _syncDetailFields();
    } on AuthException catch (error) {
      if (mounted)
        setState(() {
          _error = error.message;
          _loading = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _error = 'Unable to load payout information. Please try again.';
          _loading = false;
        });
    }
  }

  void _syncDetailFields() {
    for (final field in _fields) {
      _detailController(field);
    }
  }

  Future<void> _submit() async {
    final wallet = _wallet;
    final option = _option;
    if (wallet == null || option == null) {
      showAuthMessage(context, 'Choose a wallet and withdrawal method.');
      return;
    }
    final major = _enteredAmount;
    if (!major.isFinite || major <= 0) {
      showAuthMessage(context, 'Enter a valid withdrawal amount.');
      return;
    }
    final balanceMinor =
        (wallet['available_balance_minor'] as num?)?.toInt() ?? 0;
    final available = balanceMinor / math.pow(10, _digits);
    if (major > available) {
      showAuthMessage(context, 'The amount is higher than your available balance.');
      return;
    }
    final scaled = major * math.pow(10, _digits);
    if ((scaled - scaled.round()).abs() > 0.000001) {
      showAuthMessage(context, 'Enter an amount with no more than $_digits decimal places.');
      return;
    }
    final minimum = _minimumMajor;
    if (minimum > 0 && major < minimum) {
      showAuthMessage(context, 'The minimum withdrawal is ${formatMajorMoney(minimum, _currency)}.');
      return;
    }
    final payout = {
      for (final field in _fields) field: _detailController(field).text.trim(),
    };
    final profileOptionId = int.tryParse(
      _savedPayoutProfile['withdrawal_option_id']?.toString() ?? '',
    );
    final selectedOptionId = int.tryParse(option['id']?.toString() ?? '');
    final savedDetails = _savedPayoutProfile['details'];
    if (profileOptionId == selectedOptionId && savedDetails is Map) {
      for (final key in const ['bank_id', 'bank_code']) {
        if (savedDetails[key] != null)
          payout[key] = savedDetails[key].toString();
      }
    }
    if (payout.values.any((value) => value.isEmpty)) {
      showAuthMessage(context, 'Complete all payout details for this method.');
      return;
    }
    final pin = _securityPinSet ? await _askForSecurityPin() : null;
    if (_securityPinSet && pin == null) return;
    if (!mounted) return;
    setState(() => _submitting = true);
    try {
      final amountMinor = (major * math.pow(10, _digits)).round();
      final response = await widget.api.post('withdrawals', widget.token, {
        'wallet_id': wallet['id'],
        'withdrawal_option_id': option['id'],
        'amount_minor': amountMinor,
        'payout_details': payout,
        'idempotency_key':
            'withdraw-mobile-${DateTime.now().microsecondsSinceEpoch}',
        if (pin != null) 'security_pin': pin,
      });
      if (!mounted) return;

      final created = response['data'];
      final receiptData = created is Map
          ? Map<String, dynamic>.from(created)
          : <String, dynamic>{};
      if (receiptData.isNotEmpty) {
        final responseDetails = receiptData['payout_details'];
        final displayDetails = responseDetails is Map
            ? Map<String, dynamic>.from(responseDetails)
            : Map<String, dynamic>.from(payout);
        displayDetails.remove('bank_id');
        displayDetails.remove('bank_code');
        receiptData['payout_details'] = displayDetails;
        receiptData['option'] = receiptData['option'] is Map
            ? Map<String, dynamic>.from(receiptData['option'] as Map)
            : Map<String, dynamic>.from(option);
        receiptData['wallet_name'] = wallet['label']?.toString() ?? 'Wallet';
        receiptData['wallet'] = <String, dynamic>{
          'wallet_type': wallet['type']?.toString(),
        };
        receiptData['amount_minor'] = receiptData['amount_minor'] ?? amountMinor;
        receiptData['fee_minor'] = receiptData['fee_minor'] ?? 0;
        receiptData['currency'] =
            receiptData['currency']?.toString() ?? _currency;
        receiptData['status'] = receiptData['status']?.toString() ?? 'pending';
        receiptData['requested_at'] =
            receiptData['requested_at']?.toString() ??
            DateTime.now().toIso8601String();
      }

      _amount.clear();
      for (final controller in _details.values) {
        controller.clear();
      }

      if (receiptData.isNotEmpty) {
        await showWithdrawalReceiptDialog(
          context,
          withdrawal: receiptData,
          appName: 'TLStore',
          logoAsset: 'assets/logo.jpg',
          api: widget.api,
          token: widget.token,
          receiptPath: (receipt) => 'withdrawals/${receipt.id}/receipt',
          onReceiptReady: (receipt, bytes, fileName) =>
              deliverPdfReceipt(bytes, fileName),
        );
      } else {
        showAuthMessage(
          context,
          response['message']?.toString() ??
              'Withdrawal request submitted for admin approval.',
        );
      }
      await _load();
    } on AuthException catch (error) {
      if (mounted) showAuthMessage(context, error.message);
    } catch (_) {
      if (mounted)
        showAuthMessage(
          context,
          'Could not submit the request. Please try again.',
        );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<String?> _askForSecurityPin() {
    final pin = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Confirm withdrawal',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enter your 4-digit security PIN to submit this withdrawal request.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 4,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                labelText: 'Security PIN',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              pin.text.length == 4 ? pin.text : null,
            ),
            child: Text('Continue'),
          ),
        ],
      ),
    ).whenComplete(pin.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: const Text('Payouts', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _loading || _submitting ? null : _load,
            tooltip: 'Refresh payouts',
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorView()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _balanceCard(),
                          const SizedBox(height: 28),
                          _heading('Make a withdrawal', 'Move your earnings to a destination of your choice.'),
                          const SizedBox(height: 16),
                          _requestCard(),
                          const SizedBox(height: 30),
                          _heading('Recent activity', 'Tap a request to view its receipt.',
                              trailing: _requests.isEmpty ? null : 'Showing ${math.min(_requests.length, 10)}'),
                          const SizedBox(height: 16),
                          if (_requests.isEmpty) _emptyRequests() else
                            ..._requests.take(10).map((r) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _PayoutRow(request: r, api: widget.api,
                                  token: widget.token),
                            )),
                          const SizedBox(height: 12),
                          _securityNote(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _bubble(Icons.cloud_off_rounded),
        const SizedBox(height: 16),
        Text('Could not load payouts', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
      ]),
    ),
  );

  Widget _balanceCard() {
    final wallet = _wallet;
    final name = wallet?['label']?.toString() ?? _pretty(wallet?['type']?.toString() ?? 'Earnings wallet');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF102F2B), Color(0xFF19594A), Color(0xFF28735B)]),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: const Color(0xFF164B3C).withValues(alpha: .20),
            blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.account_balance_wallet_outlined, color: Color(0xFFBDEBD5), size: 21),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(30)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.shield_outlined, color: Color(0xFFD5F3E4), size: 14),
              SizedBox(width: 5),
              Text('SECURE PAYOUTS', style: TextStyle(color: Color(0xFFD5F3E4),
                  fontSize: 10, letterSpacing: .8, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
        const SizedBox(height: 25),
        const Text('Available to withdraw', style: TextStyle(color: Color(0xFFC1DFD3), fontSize: 13)),
        const SizedBox(height: 6),
        Text(wallet == null ? 'No eligible wallet' : formatMajorMoney(_availableMajor, _currency),
            style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -.8)),
        const SizedBox(height: 18),
        Container(height: 1, color: Colors.white.withValues(alpha: .15)),
        const SizedBox(height: 15),
        Row(children: [
          const Icon(Icons.circle, size: 7, color: Color(0xFF9FE5BD)),
          const SizedBox(width: 8),
          Expanded(child: Text(wallet == null ? 'Choose an eligible wallet to get started' : name,
              style: const TextStyle(color: Color(0xFFE2F2EA), fontSize: 12, fontWeight: FontWeight.w600))),
          if (wallet != null) Text(_currency, style: const TextStyle(color: Color(0xFFC1DFD3), fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }

  Widget _requestCard() {
    final colors = Theme.of(context).colorScheme;
    final days = (_packagePlan['withdrawal_days'] as List? ?? const []).join(', ');
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(22), border: Border.all(color: colors.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepLabel('01', 'From wallet', 'Select the earnings you want to withdraw.'),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          value: (_wallet?['id'] as num?)?.toInt(),
          isExpanded: true,
          decoration: _decoration('Earnings wallet', Icons.account_balance_wallet_outlined),
          items: _wallets.map((w) {
            final currency = w['currency']?.toString() ?? 'USD';
            final balance = ((w['available_balance_minor'] as num?)?.toDouble() ?? 0) /
                math.pow(10, currencyPrecision(currency));
            return DropdownMenuItem<int>(value: (w['id'] as num).toInt(),
                child: Text('${w['label'] ?? _pretty(w['type']?.toString() ?? 'Earnings')} · ${formatMajorMoney(balance, currency)}',
                    overflow: TextOverflow.ellipsis));
          }).toList(),
          onChanged: _submitting ? null : (id) => setState(() {
            _wallet = _wallets.where((w) => (w['id'] as num).toInt() == id).firstOrNull;
            _packagePlan = _planForWallet(_wallet, _subscriptionContext);
            _amount.clear();
          }),
        ),
        if (_wallets.isEmpty) _notice('No eligible earnings wallet was found. Top-up funds cannot be withdrawn.'),
        if (_packagePlan.isNotEmpty) ...[
          const SizedBox(height: 10),
          _infoLine(Icons.calendar_month_outlined,
              '${_packagePlan['name'] ?? 'Active'} plan${days.isEmpty ? '' : ' · Withdrawal days: $days'}'),
        ],
        _sectionDivider(),
        _stepLabel('02', 'Payout method', 'Choose where your money should go.'),
        const SizedBox(height: 14),
        if (_options.isEmpty) _notice('There are currently no payout methods available.')
        else ..._options.map(_methodTile),
        _sectionDivider(),
        _stepLabel('03', 'Amount', 'Enter the amount in your wallet currency.'),
        const SizedBox(height: 14),
        TextField(
          controller: _amount,
          enabled: !_submitting && _wallet != null,
          keyboardType: TextInputType.numberWithOptions(decimal: _digits > 0),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: _decoration('Amount ($_currency)', Icons.payments_outlined,
              hint: '0${_digits > 0 ? '.${''.padRight(_digits, '0')}' : ''}').copyWith(
            suffixIcon: TextButton(
              onPressed: _wallet == null || _submitting ? null : () {
                _amount.text = _availableMajor.toStringAsFixed(_digits);
              },
              child: const Text('MAX', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _infoLine(Icons.info_outline_rounded,
            'Available: ${formatMajorMoney(_availableMajor, _currency)}${_minimumMajor > 0 ? ' · ${_methodMinimumMajorInWallet == null || _packageMinimumMajorInWallet == null ? 'Known minimum' : 'Minimum'}: ${formatMajorMoney(_minimumMajor, _currency)}' : ''}'),
        if (_option != null && (_methodMinimumMajorInWallet == null || _packageMinimumMajorInWallet == null))
          _notice('Some minimums could not be converted to $_currency${_methodMinimumMajorInWallet == null ? '. Method minimum: ${_option?['min_withdrawal']} ${_option?['currency'] ?? 'USD'}' : ''}. Your eligibility will be checked when you submit.'),
        if (_option != null) ...[const SizedBox(height: 14), _feeBreakdown()],
        if (_fields.isNotEmpty) ...[
          _sectionDivider(),
          _stepLabel('04', 'Destination details', 'Double-check your details before submitting.'),
          const SizedBox(height: 14),
          ..._fields.map((field) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _detailController(field),
              enabled: !_submitting,
              keyboardType: _keyboardFor(field),
              textCapitalization: _capitalizationFor(field),
              autocorrect: false,
              decoration: _decoration(_pretty(field), _fieldIcon(field), hint: _fieldHint(field)),
            ),
          )),
        ],
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, height: 54,
          child: FilledButton(
            onPressed: _submitting || _wallets.isEmpty || _options.isEmpty ? null : _submit,
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: _submitting
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: colors.onPrimary))
                : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('Submit payout request', style: TextStyle(fontWeight: FontWeight.w800)),
                    SizedBox(width: 10), Icon(Icons.arrow_forward_rounded, size: 18),
                  ]),
          ),
        ),
        const SizedBox(height: 12),
        Center(child: Text('Requests are reviewed before processing.', textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12))),
      ]),
    );
  }

  Widget _methodTile(Map<String, dynamic> option) {
    final colors = Theme.of(context).colorScheme;
    final selected = option['id'] == _option?['id'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? colors.primaryContainer.withValues(alpha: .55) : colors.surface,
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          onTap: _submitting ? null : () => setState(() { _option = option; _syncDetailFields(); }),
          borderRadius: BorderRadius.circular(15),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(15),
                border: Border.all(color: selected ? colors.primary : colors.outlineVariant, width: selected ? 1.5 : 1)),
            child: Row(children: [
              Container(width: 44, height: 44, alignment: Alignment.center,
                  decoration: BoxDecoration(color: selected ? colors.primaryContainer : colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12)),
                  child: Text(option['icon']?.toString() ?? '•', style: const TextStyle(fontSize: 21))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(option['name']?.toString() ?? 'Payout method', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                const SizedBox(height: 3),
                Text(option['description']?.toString() ?? 'Payout method',
                    style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text('${option['tax'] ?? '0'}% fee', style: TextStyle(color: colors.primary, fontSize: 11, fontWeight: FontWeight.w700)),
              ])),
              const SizedBox(width: 8),
              Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? colors.primary : colors.onSurfaceVariant, size: 21),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _feeBreakdown() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: colors.surfaceContainerHighest.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('PAYOUT SUMMARY', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10,
            letterSpacing: 1, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        _feeLine('Withdrawal amount', _enteredAmount > 0 ? formatMajorMoney(_enteredAmount, _currency) : '—'),
        _feeLine('Method fee (${_feeRate.toStringAsFixed(2)}%)', _enteredAmount > 0 ? '− ${formatMajorMoney(_fee, _currency)}' : '—'),
        Divider(height: 22, color: colors.outlineVariant),
        _feeLine('Estimated payout', _enteredAmount > 0 ? formatMajorMoney(math.max(0, _enteredAmount - _fee).toDouble(), _currency) : '—', bold: true),
        const SizedBox(height: 6),
        Text('Final amounts are confirmed when your request is processed.',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11, height: 1.4)),
      ]),
    );
  }

  Widget _feeLine(String label, String value, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(color: bold ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12, fontWeight: bold ? FontWeight.w800 : FontWeight.w500))),
      Flexible(child: Text(value, textAlign: TextAlign.end, style: TextStyle(fontSize: bold ? 15 : 12,
          fontWeight: FontWeight.w800, color: bold ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface))),
    ]),
  );

  Widget _emptyRequests() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 18),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18), border: Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
    child: Column(children: [
      _bubble(Icons.receipt_long_outlined),
      const SizedBox(height: 12),
      const Text('No payouts yet', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
      const SizedBox(height: 5),
      Text('Your requests and their status will appear here.', textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
    ]),
  );

  Widget _securityNote() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(16)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.shield_outlined, color: Theme.of(context).colorScheme.onPrimaryContainer, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text('Keep your account safe. Never share your security PIN with anyone.',
          style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 12, height: 1.45))),
    ]),
  );

  Widget _heading(String title, String subtitle, {String? trailing}) => Row(
    crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.3)),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, height: 1.4)),
      ])),
      if (trailing != null) Text(trailing, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 11, fontWeight: FontWeight.w700)),
    ],
  );

  Widget _stepLabel(String number, String label, String subtitle) => Row(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 34, height: 34, alignment: Alignment.center,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
          child: Text(number, style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 11, fontWeight: FontWeight.w900))),
      const SizedBox(width: 11),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
      ])),
    ],
  );

  Widget _sectionDivider() => Padding(padding: const EdgeInsets.symmetric(vertical: 22),
      child: Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant));

  Widget _infoLine(IconData icon, String text) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(icon, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
    const SizedBox(width: 6),
    Expanded(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11, height: 1.4))),
  ]);

  Widget _notice(String message) => Container(
    width: double.infinity, margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      Icon(Icons.info_outline_rounded, color: Theme.of(context).colorScheme.onTertiaryContainer, size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer, fontSize: 12, height: 1.4))),
    ]),
  );

  InputDecoration _decoration(String label, IconData icon, {String? hint}) => InputDecoration(
    labelText: label, hintText: hint,
    prefixIcon: Icon(icon, size: 19, color: Theme.of(context).colorScheme.onSurfaceVariant),
    filled: true, fillColor: Theme.of(context).colorScheme.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(13)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.5)),
  );

  Widget _bubble(IconData icon) => Container(width: 44, height: 44,
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(13)),
    child: Icon(icon, color: Theme.of(context).colorScheme.onPrimaryContainer, size: 22));

  TextInputType _keyboardFor(String field) {
    final key = field.toLowerCase();
    if (key.contains('email')) return TextInputType.emailAddress;
    if (key.contains('phone') || key.contains('account_number'))
      return TextInputType.phone;
    return TextInputType.text;
  }

  TextCapitalization _capitalizationFor(String field) {
    final key = field.toLowerCase();
    return key.contains('email') ||
            key.contains('number') ||
            key.contains('phone') ||
            key.contains('wallet_address')
        ? TextCapitalization.none
        : TextCapitalization.words;
  }

  String _fieldHint(String field) {
    final key = field.toLowerCase();
    if (key.contains('email')) return 'name@example.com';
    if (key.contains('phone')) return 'Enter mobile number';
    if (key.contains('account_number')) return 'Enter account number';
    if (key.contains('wallet_address')) return 'Paste wallet address';
    return 'Enter ${_pretty(field).toLowerCase()}';
  }

  IconData _fieldIcon(String field) {
    final key = field.toLowerCase();
    if (key.contains('email')) return Icons.alternate_email_rounded;
    if (key.contains('phone')) return Icons.phone_rounded;
    if (key.contains('account')) return Icons.account_balance_outlined;
    if (key.contains('wallet')) return Icons.currency_bitcoin_rounded;
    if (key.contains('bank')) return Icons.account_balance_rounded;
    return Icons.edit_outlined;
  }
}

class _PayoutRow extends StatelessWidget {
  const _PayoutRow({
    required this.request,
    required this.api,
    required this.token,
  });
  final Map<String, dynamic> request;
  final AuthApi api;
  final String token;

  Future<void> _openReceipt(BuildContext context) async {
    await showWithdrawalReceiptDialog(
      context,
      withdrawal: request,
      appName: 'Receipt',
      logoAsset: 'assets/others/logolong.png',
      api: api,
      token: token,
      receiptPath: (receipt) => 'withdrawals/${receipt.id}/receipt',
      onReceiptReady: (receipt, bytes, fileName) =>
          deliverPdfReceipt(bytes, fileName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final option = request['option'] is Map
        ? request['option'] as Map
        : const {};
    final amount = (request['amount_minor'] as num?)?.toInt() ?? 0;
    final fee = (request['fee_minor'] as num?)?.toInt();
    final currency = request['currency']?.toString() ?? 'USD';
    final status = request['status']?.toString() ?? 'pending';
    final packageTerms = request['package_withdrawal_terms_snapshot'] is Map
        ? request['package_withdrawal_terms_snapshot'] as Map
        : const {};
    final packageDays = (packageTerms['withdrawal_days'] as List? ?? const [])
        .join(', ');
    final date =
        request['requested_at']?.toString() ??
        request['created_at']?.toString();
    final color = _statusColor(context, status.toLowerCase());
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: () => _openReceipt(context),
        borderRadius: BorderRadius.circular(17),
        child: Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  option['icon']?.toString() ?? '💸',
                  style: TextStyle(fontSize: 19),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option['name']?.toString() ?? 'Withdrawal',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      date == null ? 'Date unavailable' : _formatDate(date),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                    if (packageTerms['plan_name'] != null)
                      Text(
                        '${packageTerms['plan_name']}${packageDays.isEmpty ? '' : ' · $packageDays'}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 9,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatMajorMoney(
                      amount / math.pow(10, currencyPrecision(currency)), currency,
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _pretty(status),
                      style: TextStyle(
                        color: color,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (fee != null) ...[
            Padding(
              padding: EdgeInsets.symmetric(vertical: 11),
              child: Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Processing fee',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
                ),
                Text(
                  formatMajorMoney(
                    fee / math.pow(10, currencyPrecision(currency)), currency,
                  ),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      ),
      ),
    );
  }
}

Color _statusColor(BuildContext context, String status) {
  final colors = Theme.of(context).colorScheme;
  if (['paid', 'completed', 'approved'].contains(status)) return colors.primary;
  if (['processing', 'pending', 'review'].contains(status))
    return colors.tertiary;
  if (['failed', 'rejected', 'cancelled'].contains(status)) return colors.error;
  return colors.onSurfaceVariant;
}

String _pretty(String value) => value
    .replaceAll('_', ' ')
    .split(' ')
    .map(
      (word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}',
    )
    .join(' ');

String _formatDate(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return value;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final minute = date.minute.toString().padLeft(2, '0');
  return '${months[date.month - 1]} ${date.day}, ${date.year} • $hour:$minute ${date.hour >= 12 ? 'PM' : 'AM'}';
}
