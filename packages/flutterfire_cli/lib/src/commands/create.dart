/*
 * Copyright (c) 2016-present Invertase Limited & Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this library except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

import 'dart:io';

import 'package:ansi_styles/ansi_styles.dart';
import 'package:mason/mason.dart';

import '../bundle/flutterfire_template_bundle.dart';
import '../common/platform.dart';
import '../common/strings.dart';
import '../common/utils.dart';
import '../firebase.dart' as firebase;
import '../firebase/firebase_project.dart';
import '../flutter_app.dart';
import 'base.dart';
import 'config.dart';

class CreateCommand extends FlutterFireCommand {
  CreateCommand(FlutterApp? flutterApp) : super(flutterApp) {
    setupDefaultFirebaseCliOptions();
    argParser.addOption(
      'out',
      valueHelp: 'filePath',
      defaultsTo: 'lib${currentPlatform.pathSeparator}firebase_options.dart',
      abbr: 'o',
      help: 'The output file path of the Dart file that will be generated with '
          'your Firebase configuration options.',
    );
    argParser.addFlag(
      'yes',
      abbr: 'y',
      negatable: false,
      help:
          'Skip the Y/n confirmation prompts and accept default options (such as detected platforms).',
    );
    argParser.addOption(
      'platforms',
      valueHelp: 'platforms',
      mandatory: isCI,
      help:
          'Optionally specify the platforms to generate configuration options for '
          'as a comma separated list. For example "android,ios,macos,web,linux,windows".',
    );
    argParser.addOption(
      'ios-bundle-id',
      valueHelp: 'bundleIdentifier',
      mandatory: isCI,
      abbr: 'i',
      help: 'The bundle identifier of your iOS app, e.g. "com.example.app". '
          'If no identifier is provided then an attempt will be made to '
          'automatically detect it from your "ios" folder (if it exists).',
    );
    argParser.addOption(
      'macos-bundle-id',
      valueHelp: 'bundleIdentifier',
      mandatory: isCI,
      abbr: 'm',
      help: 'The bundle identifier of your macOS app, e.g. "com.example.app". '
          'If no identifier is provided then an attempt will be made to '
          'automatically detect it from your "macos" folder (if it exists).',
    );
    argParser.addOption(
      'android-app-id',
      valueHelp: 'applicationId',
      help:
          'DEPRECATED - use "android-package-name" instead. The application id of your Android app, e.g. "com.example.app". '
          'If no identifier is provided then an attempt will be made to '
          'automatically detect it from your "android" folder (if it exists)',
    );
    argParser.addOption(
      'android-package-name',
      valueHelp: 'packageName',
      abbr: 'a',
      help: 'The package name of your Android app, e.g. "com.example.app". '
          'If no package name is provided then an attempt will be made to '
          'automatically detect it from your "android" folder (if it exists).',
    );
    argParser.addFlag(
      'apply-gradle-plugins',
      defaultsTo: true,
      hide: true,
      abbr: 'g',
      help:
          "Whether to add the Firebase related Gradle plugins (such as Crashlytics and Performance) to your Android app's build.gradle files "
          'and create the google-services.json file in your ./android/app folder.',
    );
    argParser.addFlag(
      'app-id-json',
      defaultsTo: true,
      hide: true,
      abbr: 'j',
      help:
          'Whether to generate the firebase_app_id.json files used by native iOS and Android builds.',
    );
  }

  @override
  final String name = 'create';

  @override
  List<String> aliases = <String>[];

  @override
  final String description = 'Configure Firebase for your Flutter app. This '
      'command will fetch Firebase configuration for you and generate a '
      'Dart file with prefilled FirebaseOptions you can use.';

  bool get yes {
    return argResults!['yes'] as bool || false;
  }

  List<String> get platforms {
    final platformsString = argResults!['platforms'] as String?;
    if (platformsString == null || platformsString.isEmpty) {
      return <String>[];
    }
    return platformsString
        .split(',')
        .map((String platform) => platform.trim().toLowerCase())
        .where(
          (element) =>
              element == 'ios' ||
              element == 'android' ||
              element == 'macos' ||
              element == 'web' ||
              element == 'linux' ||
              element == 'windows',
        )
        .toList();
  }

  bool get applyGradlePlugins {
    return argResults!['apply-gradle-plugins'] as bool;
  }

  bool get generateAppIdJson {
    return argResults!['app-id-json'] as bool;
  }

  String? get androidApplicationId {
    final value = argResults!['android-package-name'] as String?;
    final deprecatedValue = argResults!['android-app-id'] as String?;

    // TODO validate packagename is valid if provided.

    if (value != null) {
      return value;
    }
    if (deprecatedValue != null) {
      logger.stdout(
        'Warning - android-app-id (-a) is deprecated. Consider using android-package-name (-p) instead.',
      );
      return deprecatedValue;
    }

    if (isCI) {
      throw FirebaseCommandException(
        'configure',
        'Please provide value for android-package-name.',
      );
    }
    return null;
  }

  String? get iosBundleId {
    final value = argResults!['ios-bundle-id'] as String?;
    // TODO validate bundleId is valid if provided
    return value;
  }

  String? get macosBundleId {
    final value = argResults!['macos-bundle-id'] as String?;
    // TODO validate bundleId is valid if provided
    return value;
  }

  String get outputFilePath {
    return argResults!['out'] as String;
  }

  String get iosAppIDOutputFilePrefix {
    return 'ios';
  }

  String get macosAppIDOutputFilePrefix {
    return 'macos';
  }

  String get androidAppIDOutputFilePrefix {
    return 'android';
  }

  Future<FirebaseProject> _promptCreateFirebaseProject() async {
    final newProjectId = promptInput(
      'Enter a project id for your new Firebase project (e.g. ${AnsiStyles.cyan('my-cool-project')})',
      validator: (String x) {
        if (RegExp(r'^[a-zA-Z0-9\-]+$').hasMatch(x)) {
          return true;
        } else {
          return 'Firebase project ids must be lowercase and contain only alphanumeric and dash characters.';
        }
      },
    );
    final creatingProjectSpinner = spinner(
      (done) {
        if (!done) {
          return 'Creating new Firebase project ${AnsiStyles.cyan(newProjectId)}...';
        }
        return 'New Firebase project ${AnsiStyles.cyan(newProjectId)} created succesfully.';
      },
    );
    final newProject = await firebase.createProject(
      projectId: newProjectId,
      account: accountEmail,
    );
    creatingProjectSpinner.done();
    return newProject;
  }

  Future<FirebaseProject> _selectFirebaseProject() async {
    var selectedProjectId = projectId;
    selectedProjectId ??= await firebase.getDefaultFirebaseProjectId();

    if ((isCI || yes) && selectedProjectId == null) {
      throw FirebaseProjectRequiredException();
    }

    List<FirebaseProject>? firebaseProjects;

    final fetchingProjectsSpinner = spinner(
      (done) {
        if (!done) {
          return 'Fetching available Firebase projects...';
        }
        final baseMessage =
            'Found ${AnsiStyles.cyan('${firebaseProjects?.length ?? 0}')} Firebase projects.';
        if (selectedProjectId != null) {
          return '$baseMessage Selecting project ${AnsiStyles.cyan(selectedProjectId)}.';
        }
        return baseMessage;
      },
    );
    firebaseProjects = await firebase.getProjects(account: accountEmail);

    fetchingProjectsSpinner.done();
    if (selectedProjectId != null) {
      return firebaseProjects.firstWhere(
        (project) => project.projectId == selectedProjectId,
        orElse: () {
          throw FirebaseProjectNotFoundException(selectedProjectId!);
        },
      );
    }

    // No projects to choose from so lets
    // prompt to create straight away.
    if (firebaseProjects.isEmpty) {
      return _promptCreateFirebaseProject();
    }

    final choices = <String>[
      ...firebaseProjects.map(
        (p) => '${p.projectId} (${p.displayName})',
      ),
      AnsiStyles.green('<create a new project>'),
    ];

    final selectedChoiceIndex = promptSelect(
      'Select a Firebase project to configure your Flutter application with',
      choices,
    );

    // Last choice is to create a new project.
    if (selectedChoiceIndex == choices.length - 1) {
      return _promptCreateFirebaseProject();
    }

    return firebaseProjects[selectedChoiceIndex];
  }

  Map<String, bool> _selectPlatforms() {
    final selectedPlatforms = <String, bool>{
      kAndroid: platforms.contains(kAndroid) ||
          platforms.isEmpty && flutterApp!.android,
      kIos: platforms.contains(kIos) || platforms.isEmpty && flutterApp!.ios,
      kMacos:
          platforms.contains(kMacos) || platforms.isEmpty && flutterApp!.macos,
      kWeb: platforms.contains(kWeb) || platforms.isEmpty && flutterApp!.web,
      if (flutterApp!.dependsOnPackage('firebase_core_desktop'))
        kWindows: platforms.contains(kWindows) ||
            platforms.isEmpty && flutterApp!.windows,
      if (flutterApp!.dependsOnPackage('firebase_core_desktop'))
        kLinux: platforms.contains(kLinux) ||
            platforms.isEmpty && flutterApp!.linux,
    };
    if (platforms.isNotEmpty || isCI || yes) {
      final selectedPlatformsString = selectedPlatforms.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toList()
          .join(',');
      logger.stdout(
        AnsiStyles.bold(
          '${AnsiStyles.blue('i')} Selected platforms: ${AnsiStyles.green(selectedPlatformsString)}',
        ),
      );
      return selectedPlatforms;
    }
    final answers = promptMultiSelect(
      'Which platforms should your configuration support (use arrow keys & space to select)?',
      selectedPlatforms.keys.toList(),
      defaultSelection: selectedPlatforms.values.toList(),
    );
    var index = 0;
    for (final key in selectedPlatforms.keys) {
      if (answers.contains(index)) {
        selectedPlatforms[key] = true;
      } else {
        selectedPlatforms[key] = false;
      }
      index++;
    }
    return selectedPlatforms;
  }

  @override
  Future<void> run() async {
    final generator =
        await MasonGenerator.fromBundle(flutterfireTemplateBundle);

    final vars = <String, String>{
      'name': 'coucou',
      'org': 'com.example',
      'description': 'coucou'
    };

    await generator.hooks.preGen(
      vars: vars,
    );
    await generator.generate(
      DirectoryGeneratorTarget(Directory('$outputFilePath/coucou')),
      vars: vars,
    );
    await generator.hooks.postGen(
      vars: vars,
    );

    final config = ConfigCommand(flutterApp);

    await config.run();
  }
}