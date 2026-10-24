/// One realistic log excerpt per diagnostic rule, with the step it comes
/// from. Excerpts marked "observed" were captured from real builds.
const ruleSamples = <String, (String step, String output)>{
  // observed: flutter pub get 3.44.8
  'UP-PUB-0002': (
    'pub get',
    '''
Resolving dependencies...
The current Dart SDK version is 3.12.2.

Because sample depends on http >=0.2.8+2 <0.13.0-nullsafety.0 which doesn't support null safety, version solving failed.

The lower bound of "sdk: '<2.0.0 or >=2.0.0-dev.61.0 <3.0.0'" must be 2.12.0 or higher to enable null safety.
For details, see https://dart.dev/null-safety


You can try the following suggestion to make the pubspec resolve:
* Try upgrading your constraint on http: flutter pub add http:^1.6.0
Failed to update packages.
'''
  ),
  // observed: flutter pub get 3.44.8
  'UP-PUB-0001': (
    'pub get',
    '''
Resolving dependencies...
The current Dart SDK version is 3.12.2.

Because blocked_app depends on progress_dialog >=1.0.0 which doesn't support null safety, version solving failed.

The lower bound of "sdk: '>=2.0.0-dev.68.0 <3.0.0'" must be 2.12.0 or higher to enable null safety.
For details, see https://dart.dev/null-safety
Failed to update packages.
'''
  ),
  'UP-PUB-0003': (
    'pub get',
    '''
The current Dart SDK version is 3.12.2.

Because my_app depends on old_pkg 1.0.0 which requires SDK version >=2.19.0 <3.5.0, version solving failed.
'''
  ),
  'UP-PUB-0004': (
    'pub get',
    '''
Because my_app depends on fancy_widget >=2.0.0 which requires Flutter SDK version >=3.50.0, version solving failed.
'''
  ),
  'UP-PUB-0006': (
    'pub get',
    '''
The current Dart SDK version is 3.12.2.

Because my_app requires SDK version >=2.19.0 <3.0.0, version solving failed.
'''
  ),
  'UP-PUB-0005': (
    'pub get',
    '''
Because every version of a depends on c ^1.0.0 and every version of b depends on c ^2.0.0, a is incompatible with b.
So, because my_app depends on both a and b, version solving failed.
'''
  ),
  // observed: Gradle 8.11 on JDK 25
  'UP-AND-0001': (
    'build apk',
    '''
Running Gradle task 'assembleDebug'...

FAILURE: Build failed with an exception.

* What went wrong:
25.0.3

* Try:
> Run with --stacktrace option to get the stack trace.
'''
  ),
  'UP-AND-0002': (
    'build apk',
    '''
FAILURE: Build failed with an exception.

* What went wrong:
Error: Your project's Android Gradle Plugin version (8.1.0) is lower than Flutter's minimum supported version of 8.6.0. Please upgrade your Android Gradle Plugin version.
Alternatively, use the flag "--android-skip-build-dependency-validation" to bypass this check.
'''
  ),
  'UP-AND-0003': (
    'build apk',
    '''
Error: Your project's Gradle version (8.3) is lower than Flutter's minimum supported version of 8.7.0. Please upgrade your Gradle version.
'''
  ),
  'UP-AND-0004': (
    'build apk',
    '''
Error: Your project's Kotlin version (1.8.22) is lower than Flutter's minimum supported version of 2.0.0. Please upgrade your Kotlin version.
'''
  ),
  'UP-AND-0005': (
    'build apk',
    '''
Error: Your project's Java version (11) is lower than Flutter's minimum supported version of 17. Please upgrade your Java version.
'''
  ),
  'UP-AND-0006': (
    'build apk',
    '''
* What went wrong:
An exception occurred applying plugin request [id: 'com.android.application']
> Failed to apply plugin 'com.android.internal.application'.
   > Minimum supported Gradle version is 8.13. Current version is 8.3. If using the gradle wrapper, try editing the distributionUrl in /tmp/x/android/gradle/wrapper/gradle-wrapper.properties to gradle-8.13-all.zip
'''
  ),
  'UP-AND-0007': (
    'build apk',
    '''
* What went wrong:
An exception occurred applying plugin request [id: 'kotlin-android']
> Failed to apply plugin 'kotlin-android'.
   > The 'org.jetbrains.kotlin.android' plugin is no longer required for Kotlin support since AGP 9.0.
'''
  ),
  'UP-AND-0008': (
    'build apk',
    '''
* What went wrong:
An exception occurred applying plugin request [id: 'dev.flutter.flutter-gradle-plugin']
> Failed to apply plugin 'dev.flutter.flutter-gradle-plugin'.
   > java.lang.NullPointerException (no error message)
'''
  ),
  'UP-AND-0009': (
    'build apk',
    '''
e: /x/build.gradle.kts: Class 'kotlin.Unit' was compiled with an incompatible version of Kotlin. The binary version of its metadata is 2.1.0, expected version is 1.8.0.
'''
  ),
  'UP-AND-0010': (
    'build apk',
    '''
The current Gradle version 7.4.2 is not compatible with the Kotlin Gradle plugin. Please use Gradle 7.6.3 or newer, or the previous version of the Kotlin plugin.
'''
  ),
  'UP-AND-0011': (
    'build apk',
    '''
uses-sdk:minSdkVersion 21 cannot be smaller than version 23 declared in library [:camera_android] /x/build/camera_android/intermediates/merged_manifest/debug/AndroidManifest.xml as the library might be using APIs not available in 21
'''
  ),
  'UP-AND-0012': (
    'build apk',
    '''
> The minCompileSdk (35) specified in a
     dependency's AAR metadata (META-INF/com/android/build/gradle/aar-metadata.properties)
     is greater than this module's compileSdkVersion (android-34).
'''
  ),
  'UP-AND-0013': (
    'build apk',
    '''
> Failed to apply plugin 'com.android.internal.application'.
   > Android Gradle plugin requires Java 17 to run. You are currently using Java 11.
'''
  ),
  'UP-AND-0014': (
    'build apk',
    '''
* What went wrong:
A problem occurred configuring project ':flutter_old_plugin'.
> Could not create an instance of type com.android.build.api.variant.impl.LibraryVariantBuilderImpl.
   > Namespace not specified. Specify a namespace in the module's build file: /home/dev/.pub-cache/hosted/pub.dev/flutter_old_plugin-0.3.1/android/build.gradle. See https://d.android.com/r/tools/upgrade-assistant/set-namespace for information about setting the namespace.
'''
  ),
  'UP-AND-0015': (
    'build apk',
    '''
ERROR:/x/build/app/intermediates/merged_res/debug/values/values.xml: AAPT: error: RES_TABLE_TYPE_TYPE entry offsets overlap actual entry data.
'''
  ),
  'UP-AND-0016': (
    'build apk',
    '''
/home/dev/.pub-cache/hosted/pub.dev/old_camera-0.5.8/android/src/main/java/io/flutter/plugins/camera/CameraPlugin.java:42: error: cannot find symbol
  public static void registerWith(PluginRegistry.Registrar registrar) {
'''
  ),
  'UP-AND-0017': (
    'build apk',
    '''
> Failed to transform core-for-system-modules.jar to match attributes {artifactType=_internal_android_jdk_image}.
   > Execution failed for JdkImageTransform: /x/android-34/core-for-system-modules.jar.
      > Error while executing process /opt/jdk-21/bin/jlink with arguments {--module-path ...}
'''
  ),
  'UP-AND-0018': (
    'build apk',
    '''
Exception in thread "main" java.io.FileNotFoundException: https://github.com/gradle/gradle-distributions/releases/download/v8.14.0/gradle-8.14.0-all.zip
	at java.base/sun.net.www.protocol.http.HttpURLConnection.getInputStream0(Unknown Source)
'''
  ),
  'UP-AND-0019': (
    'build apk',
    '''
e: file:///home/dev/.pub-cache/hosted/pub.dev/legacy_share-2.0.4/android/src/main/kotlin/dev/share/SharePlugin.kt:15:9 Unresolved reference 'registrar'.
'''
  ),
  'UP-AND-0020': (
    'build apk',
    '''
* What went wrong:
Execution failed for task ':app:compileDebugKotlin'.
> Inconsistent JVM-target compatibility detected for tasks 'compileDebugJavaWithJavac' (1.8) and 'compileDebugKotlin' (17).
'''
  ),
  'UP-DART-0001': (
    'build apk',
    '''
../../.pub-cache/hosted/pub.dev/fancy_text-1.2.0/lib/src/fancy.dart:42:10: Error: The getter 'headline1' isn't defined for the class 'TextTheme'.
'''
  ),
  'UP-DART-0002': (
    'build apk',
    '''
lib/main.dart:31:22: Error: The getter 'headline1' isn't defined for the class 'TextTheme'.
'''
  ),
  'UP-IOS-0001': (
    'build ios',
    '''
[!] CocoaPods could not find compatible versions for pod "firebase_core":
  Specs satisfying the `firebase_core (from `.symlinks/plugins/firebase_core/ios`)` dependency were found, but they required a higher minimum deployment target.
'''
  ),
  'UP-IOS-0002': (
    'build ios',
    '''
CocoaPods's specs repository is too out-of-date to satisfy dependencies.
To update the CocoaPods specs, run:
  pod repo update
'''
  ),
  'UP-IOS-0003': (
    'build ios',
    '''
Xcode installation is incomplete; a full installation is necessary for iOS development.
'''
  ),
  'UP-ENV-0001': (
    'build apk',
    '''
java.io.IOException: No space left on device
'''
  ),
  'UP-ENV-0002': (
    'build apk',
    '''
> Could not resolve com.android.tools.build:gradle:8.11.1.
   > Could not GET 'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/8.11.1/gradle-8.11.1.pom'.
'''
  ),
  'UP-ENV-0003': (
    'build apk',
    '''
* What went wrong:
Could not determine the dependencies of task ':app:compileDebugJavaWithJavac'.
> SDK location not found. Define a valid SDK location with an ANDROID_HOME environment variable.
'''
  ),
  // observed: interrupted NDK download on this machine
  'UP-ENV-0005': (
    'build apk',
    '''
* What went wrong:
A problem occurred evaluating root project 'android'.
> A problem occurred configuring project ':app'.
   > [CXX1101] NDK at /home/dev/Library/Android/sdk/ndk/28.2.13676358 did not have a source.properties file
'''
  ),
  'UP-ENV-0004': (
    'build apk',
    '''
Execution failed for task ':app:mergeDebugResources'.
> java.lang.OutOfMemoryError: Java heap space
'''
  ),
};
