// NOVA Nebula Dark Premium theme values.
// Source: ~/workspace/nova-design/NOVA-NEBULA-DESIGN.md
// (background #0A0C1C, cards #14172B, primary #8B5CF6, gradient
// #7C3AED -> #3B82F6, secondary #22D3EE, pink #EC4899).
import 'package:material_ui/material_ui.dart';

class NebulaColors {
  static const Color background = Color(0xFF0A0C1C);
  static const Color card = Color(0xFF14172B);
  static const Color cardElevated = Color(0xFF1B1F38);
  static const Color primary = Color(0xFF8B5CF6);
  static const Color gradientStart = Color(0xFF7C3AED);
  static const Color gradientEnd = Color(0xFF3B82F6);
  static const Color secondary = Color(0xFF22D3EE);
  static const Color pink = Color(0xFFEC4899);
  static const Color textPrimary = Color(0xFFF1F2FA);
  static const Color textSecondary = Color(0xFF9AA0B8);
  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color error = Color(0xFFF87171);

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [gradientStart, gradientEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

ThemeData nebulaTheme() {
  const colorScheme = ColorScheme.dark(
    primary: NebulaColors.primary,
    secondary: NebulaColors.secondary,
    surface: NebulaColors.card,
    error: NebulaColors.error,
    onPrimary: Colors.white,
    onSecondary: Colors.black,
    onSurface: NebulaColors.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: NebulaColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: NebulaColors.background,
      foregroundColor: NebulaColors.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: NebulaColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NebulaColors.card,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: NebulaColors.primary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: NebulaColors.textSecondary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: NebulaColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: NebulaColors.cardElevated,
      contentTextStyle: TextStyle(color: NebulaColors.textPrimary),
    ),
    dividerColor: Colors.white.withValues(alpha: 0.08),
  );
}
