# ZuzurroFlow para Windows

App hermana de ZuzurroFlow para macOS (repo `kueyoshop/zuzurro`, carpeta `app/`). Fork rebrandeado de Handy (MIT, cjpais/Handy) — Tauri v2 + Rust + whisper.cpp/Parakeet local. **Misión: paridad funcional con la versión Mac**, trabajando EN el PC Windows del usuario junto a él.

## Para retomar el trabajo

1. **Lee `docs/PARITY-PLAN.md`** — fases de paridad, estado, y el mapa de qué portar desde la app Mac.
2. La ESPECIFICACIÓN de cada feature vive en el repo Mac (`kueyoshop/zuzurro`): prompts del pulido en `app/Sources/ZuzurroFlow/Formatting/FormatterPrompt.swift`, lógica de espaciado en `AppDelegate.deliver`, diccionario/aprendizaje en `Dictionary/`, toasts en `UI/Toast/`.

## Reglas del proyecto (heredadas)

- Hablar al usuario en **español**. NO sabe programar ni usar terminal: acciones suyas = pasos de doble clic con instrucciones exactas.
- Transcripción **local** (Parakeet/whisper.cpp que Handy ya trae). Datos 100% independientes del Mac (requisito explícito).
- Pulido IA en Windows: sin Apple FM → decidir allí entre llama.cpp local pequeño o Claude vía kie.ai (clave del usuario en el Mac, defaults com.zuzurro.flow → pedírsela). Los 3 candados anti-invención (marcas <dictado>, tope de tokens, validación por solapamiento) son OBLIGATORIOS — ver FormatterPrompt.swift.
- Portapapeles del sistema jamás contaminado; espacio inteligente DELANTE del dictado.
- Sonidos: `assets` wav de Wispr (uso personal del usuario, no redistribuir) — están en el repo Mac `app/Resources/Sounds/`.
- Nunca reactivar el updater de Handy (eliminado de tauri.conf.json a propósito).

## Build local (en el PC)

Requisitos: Rust (rustup), Bun, VS Build Tools C++. Luego: `bun install && bun tauri dev` (dev) o `bun tauri build` (instalador). CI alternativo: workflow "ZuzurroFlow Windows Build" (Actions) compila el .exe sin firmar.

## Bootstrap en el PC Windows (primera sesión)

Si acabas de arrancar en el PC del usuario:
1. Si falta git: `winget install --id Git.Git -e` (o descarga silenciosa).
2. La spec de la app Mac YA ESTÁ COPIADA en `docs/mac-reference/` (leer su
   README) y los sonidos en `assets/sounds-wispr/`. No necesitas ningún repo
   privado ni autenticación de GitHub para trabajar.
   (Si la carpeta llegó como ZIP sin `.git`: `git init` + remoto
   `https://github.com/kueyoshop/zuzurroflow-windows.git` cuando toque subir.)
3. Sigue `docs/PARITY-PLAN.md` desde W1. Idioma: español. El usuario no usa terminal.
