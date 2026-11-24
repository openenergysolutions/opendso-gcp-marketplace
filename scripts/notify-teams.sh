#!/bin/bash
#
# notify-teams.sh — Post a short alert card to a Microsoft Teams webhook.
# Used by CI workflows; does nothing when TEAMS_WEBHOOK_URL is unset.
#
# Environment:
#   TEAMS_WEBHOOK_URL  Incoming webhook URL (optional)
#   TITLE              Card title
#   RUN_URL            Link for the "View run" button
set -euo pipefail

if [[ -z "${TEAMS_WEBHOOK_URL:-}" ]]; then
    echo "TEAMS_WEBHOOK_URL not set; skipping Teams notification"
    exit 0
fi

jq -n \
    --arg title "${TITLE:-CI alert}" \
    --arg repo "${GITHUB_REPOSITORY:-}" \
    --arg url "${RUN_URL:-}" \
    '{
      "type": "message",
      "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          "type": "AdaptiveCard",
          "version": "1.2",
          "body": [
            {"type": "TextBlock", "size": "Large", "weight": "Bolder", "color": "Attention", "text": $title},
            {"type": "FactSet", "facts": [{"title": "Repository", "value": $repo}]}
          ],
          "actions": [{"type": "Action.OpenUrl", "title": "View run", "url": $url}]
        }
      }]
    }' \
  | curl -fsS -X POST -H "Content-Type: application/json" --data @- "$TEAMS_WEBHOOK_URL" >/dev/null
