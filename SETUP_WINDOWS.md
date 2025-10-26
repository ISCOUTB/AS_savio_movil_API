Resumen de configuración (Windows)

Pasos realizados para dejar el proyecto listo para compilación Android:

1) Instalación de herramientas (automática vía script)
   - Se intentó instalar Git y OpenJDK 17 (Temurin) con `winget`.
   - Si winget no estaba disponible, el script avisaba y pedía instalar manualmente.

2) Instalación de Flutter SDK
   - Clonado Flutter (canal `stable`) en `C:\dev\flutter` (si no existía).
   - Añadido `C:\dev\flutter\bin` al `PATH` de la sesión y del usuario.

3) Java y `JAVA_HOME`
   - Si no se encontraba `java` en el PATH, el script instaló Microsoft OpenJDK 17.
   - En este caso concreto encontramos `java.exe` en el JBR de Android Studio y lo usamos.
   - Se fijó `JAVA_HOME` a `C:\Program Files\Android\Android Studio\jbr` en la sesión y (opcional) en las variables de usuario.

4) Ajustes en Gradle
   - Se corrigió `android/settings.gradle.kts` para validar `local.properties` y evitar NPEs.
   - Se añadió verificación para que exista `packages/flutter_tools/gradle` y mostrar un mensaje claro si no.

5) Comprobaciones y build
   - Ejecutado `flutter doctor` y `.\\gradlew.bat assembleDebug --stacktrace`.
   - La build terminó SUCCESSFUL en la máquina del desarrollador (198 tasks, 1m39s).

Advertencias observadas
- Varias bibliotecas muestran advertencias por `package="..."` en su AndroidManifest (son advertencias, no fallan la compilación).
- Java 21 mostró avisos sobre compatibilidad con source/target Java 8; se recomienda usar Java toolchain o JDK 17 si aparecen problemas en tiempo de compilación.
  - Para suprimir la advertencia: añadir `android.javaCompile.suppressSourceTargetDeprecationWarning=true` en `gradle.properties`.

Comandos útiles

# Ver Java
java -version

# Ejecutar gradle (desde android/)
.\\gradlew.bat assembleDebug --stacktrace

# Aceptar licencias Android
flutter doctor --android-licenses

Notas finales
- Si prefieres una instalación completamente controlada, revisa y ejecuta `scripts/setup_flutter_windows.ps1` desde la raíz del repo.
- Recomendación: instalar Temurin 17 y apuntar `JAVA_HOME` a ese JDK si necesitas reproducir builds en CI o evitar advertencias futuras.
