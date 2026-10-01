import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../core/database/enums.dart';

/// Icon keys stored in categories.icon / accounts.icon.
const iconRegistry = <String, IconData>{
  'salary': Icons.payments_outlined,
  'freelance': Icons.work_outline,
  'allowance': Icons.wallet_giftcard_outlined,
  'gift': Icons.card_giftcard_outlined,
  'interest': Icons.percent,
  'food': Icons.restaurant_outlined,
  'transport': Icons.directions_car_outlined,
  'bills': Icons.receipt_long_outlined,
  'shopping': Icons.shopping_bag_outlined,
  'entertainment': Icons.movie_outlined,
  'health': Icons.favorite_border,
  'education': Icons.school_outlined,
  'development': Icons.trending_up,
  'family': Icons.family_restroom_outlined,
  'personal_care': Icons.spa_outlined,
  'subscription': Icons.subscriptions_outlined,
  'home': Icons.home_outlined,
  'phone': Icons.phone_iphone,
  'coffee': Icons.local_cafe_outlined,
  'travel': Icons.flight_outlined,
  'pet': Icons.pets_outlined,
  'sport': Icons.fitness_center_outlined,
  'charity': Icons.volunteer_activism_outlined,
  'bank': Icons.account_balance_outlined,
  'ewallet': Icons.account_balance_wallet_outlined,
  'cash': Icons.payments_outlined,
  'savings': Icons.savings_outlined,
  'card': Icons.credit_card,
  'transfer': Icons.swap_horiz,
  'other': Icons.category_outlined,
};

IconData iconFor(String? key) => iconRegistry[key] ?? Icons.category_outlined;

IconData accountTypeIcon(AccountType t) => switch (t) {
  AccountType.bank => Icons.account_balance_outlined,
  AccountType.ewallet => Icons.account_balance_wallet_outlined,
  AccountType.cash => Icons.payments_outlined,
  AccountType.savings => Icons.savings_outlined,
  AccountType.other => Icons.wallet_outlined,
};

/// Circular monochrome icon avatar used in lists.
class IconAvatar extends StatelessWidget {
  const IconAvatar(this.icon, {super.key, this.size = 40});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: context.fin.surface2,
      borderRadius: BorderRadius.circular(size * 0.32),
    ),
    child: Icon(icon, size: size * 0.5, color: context.fin.text),
  );
}
