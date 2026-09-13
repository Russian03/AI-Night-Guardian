pubspec.yaml -> easy_localization: ^3.0.3

crear carpeta assets/translations
	- es.json
	- ca.json
	- en.json

pubspec.yaml -> flutter:
  		    assets:
  		        - assets/translations/

main.dart -> import 'package:easy_localization/easy_localization.dart';
main.dart -> await EasyLocalization.ensureInitialized();
main.dart -> modif runApp();
main.dart -> modif MaterialApp();

import 'package:easy_localization/easy_localization.dart';
Text('btn_escucha'.tr())
context.setLocale(Locale('ca')); // Automáticamente toda la app cambia a catalán