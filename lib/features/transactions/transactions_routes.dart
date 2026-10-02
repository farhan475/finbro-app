import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../accounts/presentation/account_detail_screen.dart';
import '../accounts/presentation/account_form_screen.dart';
import '../accounts/presentation/accounts_screen.dart';
import '../categories/presentation/categories_screen.dart';
import '../categories/presentation/category_form_screen.dart';
import 'presentation/transaction_detail_screen.dart';
import 'presentation/transaction_form_screen.dart';

T? _enumParam<T extends DbEnum>(List<T> values, String? raw) =>
    values.where((v) => v.db == raw).firstOrNull;

/// Transactions (`/transaction`), accounts (`/accounts`) and categories
/// (`/categories`). Literal paths precede parameterized ones.
final List<RouteBase> transactionsRoutes = [
  GoRoute(
    path: '/transaction/new',
    builder: (_, s) => TransactionFormScreen(
      initialType: _enumParam(TransactionType.values, s.uri.queryParameters['type']),
      initialAccountId: s.uri.queryParameters['account'],
      initialTransferToAccountId: s.uri.queryParameters['to'],
    ),
  ),
  GoRoute(
    path: '/transaction/:id/edit',
    builder: (_, s) => TransactionFormScreen(transactionId: s.pathParameters['id']),
  ),
  GoRoute(
    path: '/transaction/:id',
    builder: (_, s) => TransactionDetailScreen(transactionId: s.pathParameters['id']!),
  ),
  GoRoute(path: '/accounts', builder: (_, _) => const AccountsScreen()),
  GoRoute(path: '/accounts/new', builder: (_, _) => const AccountFormScreen()),
  GoRoute(
    path: '/accounts/:id/edit',
    builder: (_, s) => AccountFormScreen(accountId: s.pathParameters['id']),
  ),
  GoRoute(
    path: '/accounts/:id',
    builder: (_, s) => AccountDetailScreen(accountId: s.pathParameters['id']!),
  ),
  GoRoute(path: '/categories', builder: (_, _) => const CategoriesScreen()),
  GoRoute(
    path: '/categories/new',
    builder: (_, s) => CategoryFormScreen(
      initialType: _enumParam(CategoryType.values, s.uri.queryParameters['type']) ?? CategoryType.expense,
    ),
  ),
  GoRoute(
    path: '/categories/:id',
    builder: (_, s) => CategoryFormScreen(categoryId: s.pathParameters['id']),
  ),
];
