# MOHAB Plus

Mod de mejoras para **Medal of Honor: Above and Beyond** (versión Oculus/Meta, Unreal Engine 4.25.3).

Es un **lanzador** que inyecta [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (v4.0.0) en el juego y carga un mod en Lua.
**No modifica ningún archivo del juego**: si arrancas el juego sin el lanzador, funciona como siempre.

## Mejoras

| Mejora | Qué hace | Por defecto |
|---|---|---|
| Jeringuillas con gatillo | La jeringuilla solo se inyecta si, además de acercarla al pecho, aprietas el **gatillo de la mano que la sostiene** (umbral configurable). | Activada |
| Jeringuillas pequeñas en la manga | Todas las jeringuillas guardadas en la manga se dibujan a escala 0.5 (configurable). Al cogerlas recuperan su tamaño real antes de llegar a la mano. | Activada |
| Vibración al recibir daño | Los dos mandos vibran al perder vida. La intensidad y la duración crecen con el daño. Opcionalmente, vibra más fuerte el mando del lado del impacto. | Activada |
| Agacharse con el stick de giro | Stick de giro **abajo** = agacharse; **arriba** = levantarse. Te mueves agachado (con la velocidad de agachado del juego). Al hacer sprint te levantas. | Activada |
| Sprint con los brazos | Modo `Arm swing`: corres al mover el stick **y** balancear los brazos como al correr, sin pulsar el stick. Es **progresivo**: cuanto más rápido mueves los brazos, más rápido corres (de la velocidad de andar al sprint máximo). Al dejar de balancearlos vuelves a andar en el acto. Modo `Click + arms`: funcionan las dos formas. | `Stick click` (como el original) |
| Velocidad de sprint | Multiplicador del sprint máximo del juego, de x1.0 a x1.5. También vale para el sprint con clic. | x1.5 |

## Requisitos

* Windows 10/11 x64 y el juego instalado desde la tienda de Oculus/Meta.
* [.NET 8 Desktop Runtime x64](https://dotnet.microsoft.com/download/dotnet/8.0) (para el lanzador).
* Funciona con Virtual Desktop y con Oculus Link/Air Link.

## Uso

1. Copia la carpeta `MOHABPlus` donde quieras. No hace falta que esté dentro del juego.
2. Abre `MOHABPlusLauncher.exe`. Detecta la carpeta del juego solo; si no, usa **Browse...**.
3. Tienes dos formas de jugar:
   * **Desde Virtual Desktop / Oculus (recomendado con VD)**: deja el lanzador abierto (o minimizado: se va a la bandeja) con la casilla
     *"Load the mod automatically..."* marcada. Lanza el juego como siempre desde VD. Unos 5 s después de que aparezca la
     ventana del juego, el mod se carga solo.
   * **Botón "Launch game with MOHAB Plus"**: arranca el juego directamente (igual que hace VD) y carga el mod.
4. La pestaña **Mod settings** del lanzador tiene las mismas opciones que el menú del juego.

Líneas de comandos (sin ventana; escriben en `launcher.log`):

```powershell
.\MOHABPlusLauncher.exe --launch
```
```powershell
.\MOHABPlusLauncher.exe --watch
```

## Menú dentro del juego

* **Mantén pulsado el botón Y (mando izquierdo) 0.8 s** para abrirlo o cerrarlo. En el juego original ese botón no hace nada.
* Aparece un panel de texto flotando delante de ti. Mientras está abierto no te mueves ni disparas.
* **Stick arriba/abajo**: elegir opción. **Stick izquierda/derecha**: cambiar valor.
* **A** o **gatillo**: activar/desactivar. **B**: cerrar.
* Los cambios se guardan en `ue4ss\Mods\MOHABPlus\config.ini` al cerrar el menú.

## Cómo funciona (resumen técnico)

* **Jeringuillas**: `BP_HealthSyringe` se inyecta cuando su componente `Box` empieza a solapar el pecho del jugador
  (`Mesh_Chest`). El Blueprint activa los eventos de solape del `Box` 0.05 s después de cogerla (`SyringeOverlapOn`).
  El mod los vuelve a apagar al instante y solo los enciende mientras aprietas el gatillo de esa mano.
  Al pulsar el gatillo se fuerza una comprobación del solape (si no, el juego esperaba a que la caja se moviera), y la caja
  sigue activa 0.4 s después de soltarlo.
  Una jeringuilla está "en la manga" si está enganchada (directa o indirectamente) a los puños, las manos o el jugador.
  Se escalan con `SetActorScale3D`. Al cogerla, el juego (`BP_MotionController:AttachObjectToHand`) lee su escala y
  luego engancha la mano a ella: por eso la escala vuelve a 1 en un pre-hook de `Actor:GetActorRelativeScale3D`, antes de
  ese enganche. Una jeringuilla agarrada nunca se reescala (si no, la mano cambiaría de tamaño).
* **Vibración**: el mod vigila la vida del `VRPlayerCharacterHealthAndDamageComponent` y usa
  `PlayerController:SetHapticsByValue`. La dirección del impacto sale de `HandleDamageLocationIndicator`.
* **Agacharse**: en modo de pie (`IsStandingMode`, lo normal) el juego no tiene agacharse por botón: deduce que estás
  agachado por la altura real de la cabeza (≤ 120 cm). El mod baja el `VROrigin` unos 60 cm con una transición suave
  (más si eres alto, para quedar por debajo de 120 cm; nunca a menos de 70 cm del suelo). Así el propio juego te trata
  como agachado: cápsula, visibilidad para la IA y velocidad. En modo sentado usa el agacharse del juego (`UserToggleVRCrouch`).
* **Sprint**: `BP_R6PlayerController.TickInput` fija `CharacterMovement.MaxWalkSpeed` en cada frame. El mod se ejecuta justo
  después (post-hook). Con el gesto pone `IsSprinting` y la velocidad entre andar (`MoveSpeedData.MaxWalkSpeed`) y
  `MaxSprintSpeed × multiplicador`, según la rapidez del balanceo. Al parar el gesto, al morir o al cambiar de pawn
  borra el estado de sprint. Nota: en modo `Stick click` el sprint se comporta como en el juego original (dura hasta que
  sueltas el stick, también al desplazarte de lado).
  El gesto se detecta con la velocidad de cada mano respecto a la cabeza (componentes adelante/arriba): manos moviéndose en
  sentidos opuestos, con media suavizada e histéresis.

## Solución de problemas

* **Opciones**: la pestaña *Mod settings* del lanzador se recarga sola cuando cambias algo en el menú del juego.
* **Log**: `ue4ss\UE4SS.log` (botón *Open UE4SS log*). Las líneas del mod empiezan por `[MOHABPlus]`. Al cargar un nivel deberías
  ver `player found` y cinco `hooked ...`.
* **Más detalle**: activa *Verbose logging* (o `debug_log=true` en `config.ini`). Con esa opción activa al arrancar el juego,
  también se habilita un canal de pruebas: escribe un comando en `ue4ss\Mods\MOHABPlus\cmd.txt`
  (`status`, `menu`, `crouch`, `stand`, `haptic`, `damage`, `set <clave> <valor>`...; lista completa en `Scripts\devtools.lua`).
* **El juego se cierra al cargar el mod**: el lanzador espera a que exista la ventana del juego antes de inyectar. Inyectar
  en el arranque del proceso hace que el juego se cierre.

## Estructura del proyecto (desarrollo)

```
launcher/                 Lanzador/inyector (.NET 8 WinForms)
mod/ue4ss/                Contenido que acompaña a UE4SS.dll (settings, mods.txt, mods Lua)
  Mods/MOHABPlus/Scripts  main, config, util, syringe, haptics, crouch, sprint, menu, devtools
  Mods/MOHABDump          Volcado de clases (solo con build -Dev)
third_party/UE4SS         Release oficial UE4SS v4.0.0 (sin modificar)
tools/                    pak_list.py, pak_extract.py, uasset_info.py, kismet_dis.py (desensamblador de Blueprints)
research/                 Volcado de clases/headers del juego generado con UE4SS
build.ps1                 Genera dist\MOHABPlus
```

Compilar:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

## Licencias

UE4SS se distribuye bajo su propia licencia (`ue4ss\UE4SS-LICENSE.txt`). Medal of Honor: Above and Beyond pertenece a
Electronic Arts / Respawn. Este mod no incluye ningún contenido del juego.
