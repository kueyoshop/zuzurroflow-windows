# Plan de paridad Windows ↔ Mac

Estado inicial (2026-07-06, preparado desde el Mac, SIN probar en Windows aún).

## Hecho esta noche (desde el Mac, a ciegas)

- Fork de Handy v0.9.0 rebrandeado: productName/identifier ZuzurroFlow, iconos del logo rojo del usuario (icon.ico/icns/PNGs), updater de Handy ELIMINADO, package.json.
- Workflow `zzf-windows.yml` (workflow_dispatch): build x64 sin firma, artifacts msi+exe.
- Primer build CI: ver Releases/Actions.

## Fase W1 — Primer arranque (CON el usuario en el PC)

1. Instalar el setup.exe de Releases (SmartScreen avisará por falta de firma: "Más información → Ejecutar de todas formas").
2. Probar el ciclo base de Handy: elegir modelo (Parakeet v3 recomendado — mismo motor que el Mac), configurar atajo (su Wispr en Windows usaba Ctrl+Win — evitar si Wispr sigue instalado allí), dictar → pegar.
3. Anotar TODO lo roto/raro. Verificar micrófono, bandeja, overlay.

## Fase W2 — Rebrand interior

Strings visibles "Handy" → "ZuzurroFlow" en la UI (grep por "Handy" en src/), acento rojo del branding, tooltip de bandeja.

## Fase W3 — Espaciado + minúscula de continuación

Port de `AppDelegate.deliver`: espacio DELANTE si el carácter antes del caret no es blanco/apertura; minúscula si la frase sigue abierta. Windows: UIAutomation (TextPattern) para leer el caret — si el campo es opaco, fallback por memoria del dictado anterior (misma app). Rust crate `uiautomation` o vía windows-rs.

## Fase W4 — Pulido IA (los 3 candados son obligatorios)

Prompts EXACTOS: copiar de FormatterPrompt.swift (limpieza + pasadas dedicadas de listas y auto-corrección + validate()). Motor a decidir en el PC según hardware:
- Opción A: llama.cpp con modelo 1.5-3B (qwen2.5-instruct) local.
- Opción B: Claude haiku vía kie.ai (lento 6-10s medido — solo como modo calidad).
- Opción C: arrancar sin pulido (raw + replacements) y decidir después.

## Fase W5 — Diccionario + replacements

Tabla SQLite (Handy ya usa una DB? verificar) + capa regex "se oye como"→palabra (port de applyDictionaryReplacements) + UI en settings. Sembrar: ZuzurroFlow, VSL, VPS, Kie, Rosamary, Zuzurro, portapapeles.

## Fase W6 — Historial + Recientes + pegar-último

Handy trae historial básico — extender: guardar raw+formatted, Recientes en tray, atajo pegar-último.

## Fase W7 — Toasts con Deshacer + cancelación recuperable + sonidos

Port de ToastController (ventana webview always-on-top pequeña) + cancel≥5s→guardar en historial + wavs de Wispr.

## Fase W8 — Aprendizaje ✨ (correcciones manuales)

UIAutomation: retener elemento con foco tras pegar + checks a 6/15/40s + findCorrections (port literal del Levenshtein/pares de CorrectionLearner.swift).

## Fase W9 — Dashboard paridad

Home con stats, Historial con Ver original, Diccionario, Ajustes de atajos con captura.
