# EIX OS · Horizon 02 — Desinstalador de apps para Windows 11

El paquete tiene cuatro partes:

- `Remove-Apps.ps1`: consulta la lista por internet y ofrece un menú para verla, elegir apps que desinstalar o solicitar agregar una app instalada.
- `apps.json`: lista que se publica junto a la página web.
- `index.html`: página para consultar la lista y abrir el formulario **Añadir una app**.
- `.github/`: formulario web y automatización que incorpora la app a la lista.

## Publicarlo una sola vez

El repositorio público `EixX0/EIX-Extermination-Apps` ya está preparado para este paquete. Sube allí todos los archivos y carpetas de este paquete, incluida `.github`. `config.json` ya apunta a ese repositorio.

1. Publica los archivos en la rama `main` del repositorio. Si lo haces con GitHub Desktop, clona el repositorio, copia los archivos del paquete a la raíz y luego haz commit y push.
2. En GitHub, abre **Settings → Pages** y selecciona publicar desde la rama `main`, carpeta `/ (root)`. Guarda. La dirección será `https://eixx0.github.io/EIX-Extermination-Apps/`.
3. En **Settings → Actions → General**, permite que los flujos tengan permisos de escritura si el repositorio los restringe. El flujo limita esos permisos a actualizar `apps.json` y cerrar la solicitud.

Si quieres usar otro repositorio, cambia `repository` y `branch` en `config.json` antes de publicar.

El repositorio es público para que el script y la página lean `apps.json`. El flujo automático acepta solicitudes del propietario o personas colaboradoras; otras cuentas no pueden modificar la lista.

## Añadir una app desde la página

1. Abre la página web publicada y pulsa **Añadir una app**; en GitHub, elige la plantilla **Agregar una app**.
2. Completa el nombre y el ID exacto de WinGet, el nombre Appx, o ambos.
3. Opcionalmente, indica la carpeta exacta del programa como `ProgramFiles/Empresa/Aplicacion`. Esa carpeta se borrará recursivamente; deja el campo vacío si no estás seguro. Las raíces permitidas son `LocalAppData`, `RoamingAppData`, `ProgramData`, `ProgramFiles` y `ProgramFilesX86`.
4. Envía el formulario. Cuando GitHub termine la actualización, la solicitud se cierra y la app aparece en la lista.

El formulario requiere iniciar sesión en GitHub con la cuenta propietaria o colaboradora del repositorio. Pide el nombre, el ID de WinGet, el paquete Appx y una carpeta de instalación opcional. No hay casilla de confirmación para agregar reportes.

La página pide la contraseña `recode` antes de mostrar la lista y el botón del formulario. Como el sitio es estático, es un bloqueo casual: la contraseña está en el archivo público de la página y `apps.json` también puede consultarse directamente. No lo uses para proteger información privada.

## Ejecutar en Windows

### Abrir el menú del script

```powershell
irm https://raw.githubusercontent.com/EixX0/EIX-Extermination-Apps/main/Remove-Apps.ps1 | iex
```

Ese comando descarga la versión actual del script desde el repositorio y abre un menú:

- **1. Desinstalar todas las apps de la lista** muestra el resumen del lote y pide escribir `BORRAR TODO`.
- **2. Ver apps instaladas en el equipo y solicitar agregar a la lista** muestra programas del Registro y paquetes Appx del usuario actual. Al elegir una y escribir `SOLICITAR`, el script muestra el título y la descripción exactos para el issue; intenta copiar la descripción al portapapeles y abre GitHub.
- **0. Salir** cierra el menú.

Pega la descripción copiada en **Description** y verifica el título mostrado por el script. Si no se encontró un ID exacto de WinGet y la app tampoco tiene paquete Appx, completa un identificador válido antes de enviar. Después de cada opción del menú, la consola y su scrollback de Windows Terminal se limpian automáticamente. El flujo solo incorpora solicitudes de la persona propietaria o colaboradora del repositorio. Puedes abrir PowerShell como administrador si Windows necesita permisos para quitar alguna app o carpeta.

Si se creó un issue en blanco por error, edítalo mientras siga abierto y reemplaza su descripción por los campos de la plantilla. El flujo vuelve a revisar issues abiertos cuando se editan.

Ejecuta el comando solo si confías en el repositorio, porque `irm | iex` ejecuta el contenido descargado. La lista actual está en `apps.json`; si está vacía, las opciones de desinstalación no harán cambios.

Para ver la lista web sin abrir el menú:

```powershell
.\Remove-Apps.ps1 -ListOnly
```

Para previsualizar el borrado de todas las apps sin desinstalar ni borrar nada:

```powershell
$script = [scriptblock]::Create((irm 'https://raw.githubusercontent.com/EixX0/EIX-Extermination-Apps/main/Remove-Apps.ps1'))
& $script -All -WhatIf
```

También puedes iniciar directamente la solicitud de una app instalada:

```powershell
.\Remove-Apps.ps1 -RequestInstalled
```

Para desinstalar una sola app de la lista por nombre:

```powershell
.\Remove-Apps.ps1 -Name "Nombre de la app"
```

## Buscar IDs y carpeta de instalación

Antes de llenar el formulario, el mismo script puede mostrar coincidencias de WinGet, nombres de paquetes Appx instalados para tu usuario y carpetas candidatas en las ubicaciones habituales:

```powershell
.\Remove-Apps.ps1 -Info -Name "Discord"
```

Si omites `-Name`, el script te preguntará qué app buscar. En las coincidencias de WinGet, copia el valor de la columna `Id`. Para Appx, copia `Name`, no `PackageFullName`. La búsqueda de carpetas candidatas revisa las carpetas de instalación habituales; verifica que sea la carpeta del programa antes de usarla. Este modo solo consulta información: no desinstala ni borra nada. Deja el campo de carpeta vacío si no estás seguro.

Si Windows bloquea la ejecución del archivo, abre PowerShell en la carpeta y usa `Unblock-File .\Remove-Apps.ps1`. El script no cambia la directiva de ejecución del equipo.

## Qué elimina

- WinGet ejecuta la desinstalación por ID exacto. Se utiliza el modo silencioso y sin selección ambigua.
- Los paquetes Appx se quitan solo para el usuario que ejecuta el script.
- La carpeta del programa es opcional y debe estar listada explícitamente. Se rechazan rutas absolutas, comodines, `.` y `..`. Solo se elimina esa carpeta específica; no se buscan carpetas automáticamente.
- No borra claves del Registro ni paquetes Appx de otras cuentas de Windows.

Una carpeta de instalación equivocada puede borrar todos sus archivos. Añade solo una ruta concreta que identifiques como carpeta del programa.

