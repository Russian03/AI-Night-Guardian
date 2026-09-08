import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const bgCanvas = Color(0xFF0B0B0D);
  static const bgElevated = Color(0xFF121214);
  static const surface = Color(0xFF131315);
  static const surfaceCard = Color(0xFF1C1C1E);
  static const surfaceContainer = Color(0xFF1F1F21);
  static const surfaceContainerHigh = Color(0xFF2A2A2C);
  static const surfaceContainerLow = Color(0xFF1B1B1D);
  static const surfaceContainerLowest = Color(0xFF0E0E10);
  static const surfaceVariant = Color(0xFF353437);
  static const surfaceBright = Color(0xFF39393B);
  static const surfaceGrouped = Color(0xFF2C2C2E);

  static const primary = Color(0xFFAAC7FF);
  static const primaryContainer = Color(0xFF3E90FF);
  static const onPrimary = Color(0xFF003064);

  static const secondary = Color(0xFF47E266);
  static const secondaryContainer = Color(0xFF09BF49);

  static const statusSuccess = Color(0xFF30D158);
  static const statusSuccessSurface = Color(0x1F30D158);
  static const statusWarning = Color(0xFFFFD60A);
  static const statusWarningSurface = Color(0x1FFFD60A);
  static const alertCritical = Color(0xFFFF453A);
  static const alertCriticalSurface = Color(0x26FF453A);
  static const alertCriticalGlow = Color(0x59FF453A);

  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0x99EBEBF5);
  static const textTertiary = Color(0x4DEBEBF5);
  static const outline = Color(0xFF8B91A0);
  static const borderSubtle = Color(0x14FFFFFF);
}

class AppTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(base.textTheme);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.bgCanvas,
      textTheme: textTheme.copyWith(
        displayLarge: textTheme.displayLarge?.copyWith(
          fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.3,
          color: AppColors.textPrimary,
        ),
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.2,
          color: AppColors.textPrimary,
        ),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.15,
          color: AppColors.textPrimary,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.1,
          color: AppColors.textPrimary,
        ),
        bodyLarge: textTheme.bodyLarge?.copyWith(
          fontSize: 17, fontWeight: FontWeight.w400,
          color: AppColors.textPrimary,
        ),
        bodyMedium: textTheme.bodyMedium?.copyWith(
          fontSize: 15, fontWeight: FontWeight.w400,
          color: AppColors.textPrimary,
        ),
        labelSmall: textTheme.labelSmall?.copyWith(
          fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.2,
          color: AppColors.textSecondary,
        ),
      ),
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.primary,
        surface: AppColors.surface,
        error: AppColors.alertCritical,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryContainer,
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.primary),
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        floatingLabelBehavior: FloatingLabelBehavior.never,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.bgElevated.withOpacity(0.9),
        selectedItemColor: AppColors.primaryContainer,
        unselectedItemColor: AppColors.textSecondary,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}