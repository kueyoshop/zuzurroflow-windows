# Referencia de la app Mac (SOLO LECTURA)

Copias congeladas (2026-07-06) del código Swift de ZuzurroFlow para macOS.
Son LA ESPECIFICACIÓN a portar — no compilar aquí, solo leer:

- `FormatterPrompt.swift` — prompts EXACTOS del pulido IA + validate() (candado
  anti-invención) + detectores de listas y auto-corrección. Portar literal.
- `Formatter.swift` — orquestación: pasada limpieza → pasada listas/backtrack
  condicionales → replacements del diccionario → mayúscula inicial.
- `CorrectionLearner.swift` — aprendizaje ✨: retener campo tras pegar, checks
  a 6/15/40s, findCorrections (Levenshtein + pares fusionados).
- `ToastController.swift` — toasts con barra de progreso y Deshacer.
- `HistoryStore.swift` — esquema SQLite (transcript + dictword) y stats.
- `HotKeyProcessor.swift` — máquina de estados del dictado (hold/doble-tap).
- `AppDelegate.swift` — pipeline completo; ver deliver() para el espaciado
  inteligente y la minúscula de continuación; cancelación recuperable.

Sonidos en `../../assets/sounds-wispr/` (uso personal del usuario, no
redistribuir): start/stop/lock/cancel/paste(desactivado en Mac a petición).
