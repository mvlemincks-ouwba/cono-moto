#!/usr/bin/env bash
# Déploie les règles de la Realtime Database et la page de suivi web
# (web_share/live.html) sur Firebase. À lancer depuis n'importe où :
#   ./firebase/deploy.sh                 # projet choisi avec « firebase use »
#   ./firebase/deploy.sh --project mon-projet
set -euo pipefail
cd "$(dirname "$0")"

# Firebase Hosting ne sert que des fichiers situés sous ce dossier :
# on y recopie la page (copie ignorée par git).
rm -rf web_share
cp -R ../web_share web_share

firebase deploy --only database,hosting "$@"
