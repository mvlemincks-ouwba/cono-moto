#!/usr/bin/env python3
"""Pont Discord ↔ GitHub pour la boîte à idées Cono Moto.

Lancé toutes les heures par .github/workflows/feedback-sync.yml. Le salon
Discord peut être un salon forum (une demande = un post, donc déjà un fil) ou
un salon texte (une demande = un message) :

1. salon texte : le bot ouvre un fil sous chaque nouvelle demande (message de
   l'appli via le webhook, ou écrit à la main) ; les messages épinglés (le
   « Comment ça marche »), ceux du bot et les messages système sont ignorés ;
2. chaque nouveau fil devient un ticket GitHub (étiquettes « feedback » +
   « idée » / « bug »), et le bot répond « bien reçu » dans le fil ;
3. le nombre de 👍 du premier message est recopié dans le ticket ;
4. les réponses des potes dans le fil Discord sont recopiées en commentaires
   du ticket (pour qu'une question posée par Claude ait sa réponse) ;
5. un commentaire GitHub contenant <!-- pour-discord --> est reposté dans le
   fil Discord (c'est ainsi que Claude répond aux potes), s'il vient du
   propriétaire du dépôt ou d'un collaborateur (le dépôt est public) ;
6. quand le ticket est fermé, le bot annonce « c'est fait » (ou « pas prévu »).

Sans dépendance (urllib). Variables d'environnement :
  DISCORD_BOT_TOKEN, DISCORD_FORUM_CHANNEL_ID (ou DISCORD_CHANNEL_ID : l'id du
  salon, texte ou forum), GITHUB_TOKEN, GITHUB_REPOSITORY
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

DISCORD_API = "https://discord.com/api/v10"
GITHUB_API = "https://api.github.com"
USER_AGENT = "ConoMotoFeedbackSync/1.0 (+https://github.com)"

THREAD_MARKER = "discord-thread"
POSTED_MARKER = "discord-posted"
NOTIFIED_MARKER = "discord-notified"
SEEN_MARKER = "discord-seen"
MESSAGE_MARKER = "discord-msg"
REPLY_MARKER = "<!-- pour-discord -->"
# Dépôt public : n'importe qui peut commenter un ticket. Seuls ces auteurs
# parlent au nom de Cono Moto dans Discord.
TRUSTED_AUTHORS = ("OWNER", "MEMBER", "COLLABORATOR")
VOTES_RE = re.compile(r"^\*\*👍 Votes :\*\* \d+$", re.M)
# « 💡 Idée : », « 🐞 Bug : »… en tête d'un titre (embed de l'appli, post du forum)
KIND_PREFIX_RE = re.compile(r"^\s*(?:💡|🐞|💬)?\s*(?:(?:idée|idee|bug|autre)\s*:\s*)?", re.I)
# Variables qui peuvent contenir l'id du salon, la première non vide gagne.
CHANNEL_ENV = ("DISCORD_FORUM_CHANNEL_ID", "DISCORD_CHANNEL_ID")
TEXT_CHANNEL_TYPES = (0, 5)  # salon texte, salon d'annonces (15 = forum)
HAS_THREAD_FLAG = 1 << 5
THREAD_NAME_MAX = 100

LABELS = {
    "feedback": ("fb6b1a", "Demande venue de la boîte à idées (Discord)"),
    "idée": ("ffb020", "Idée de fonctionnalité"),
    "bug": ("ef4444", "Quelque chose ne marche pas"),
}


# ---------------------------------------------------------------------------
# Logique pure (testée dans test_discord_sync.py)
# ---------------------------------------------------------------------------


def kind_of(thread: dict, starter: dict | None, forum_tags: dict[str, str]) -> str:
    """« bug », « idée » ou « autre », d'après les tags du forum, l'embed de
    l'appli ou le titre."""
    names = [forum_tags.get(t, "").lower() for t in thread.get("applied_tags", [])]
    text = " ".join(names) + " " + thread.get("name", "").lower()
    for e in (starter or {}).get("embeds", []):
        for f in e.get("fields", []):
            if f.get("name") == "Type":
                text += " " + f.get("value", "").lower()
    if "bug" in text or "🐞" in text:
        return "bug"
    if "idée" in text or "idee" in text or "💡" in text or "feature" in text:
        return "idée"
    return "autre"


def votes_of(starter: dict | None) -> int:
    for r in (starter or {}).get("reactions", []) or []:
        if r.get("emoji", {}).get("name") in ("👍", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"):
            return int(r.get("count", 0))
    return 0


def clean_title(name: str) -> str:
    return KIND_PREFIX_RE.sub("", name, count=1).strip() or "Sans titre"


def channel_id_from(env) -> str:
    """Id du salon : DISCORD_FORUM_CHANNEL_ID (nom historique), sinon DISCORD_CHANNEL_ID."""
    for name in CHANNEL_ENV:
        value = (env.get(name) or "").strip()
        if value:
            return value
    return ""


def is_text_channel(channel: dict) -> bool:
    """Salon texte (ou d'annonces) : le bot ouvre un fil sous chaque demande (fiche
    de l'appli, ou message qui commence par 💡 / 🐞). Sinon (forum) : chaque post
    est déjà un fil."""
    return channel.get("type") in TEXT_CHANNEL_TYPES


# Salon texte : une demande écrite à la main commence par 💡 ou 🐞 (ou
# « Idée : », « Bug : ») ; le reste est de la discussion entre potes.
EXPLICIT_REQUEST_RE = re.compile(r"^\s*(?:💡|🐞|(?:idée|idee|bug)\s*:)", re.I)


def is_explicit_request(content: str | None) -> bool:
    return bool(EXPLICIT_REQUEST_RE.match(content or ""))


def is_request_message(msg: dict | None, bot_user_id: str | None) -> bool:
    """Un message d'un salon texte est-il une demande ? Oui pour la fiche envoyée
    depuis l'appli (webhook avec le champ « Type ») et pour un message écrit à
    la main qui commence par 💡 / 🐞 (ou « Idée : » / « Bug : »). Jamais pour
    la discussion, les messages épinglés (le « Comment ça marche »), ceux de
    notre bot (« Bien reçu »…) ni les messages système."""
    if not msg or msg.get("pinned"):
        return False
    author = msg.get("author") or {}
    if bot_user_id and str(author.get("id")) == str(bot_user_id):
        return False
    if author.get("bot") and not msg.get("webhook_id"):
        return False
    if msg.get("webhook_id") and not is_app_post(msg):
        # Webhook sans la fiche de l'appli : annonce postée par Marc (mode
        # d'emploi, réponse, nouvelle version…), pas une demande.
        return False
    if msg.get("type", 0) not in (0, 19):
        return False
    if msg.get("webhook_id"):
        return True  # fiche de l'appli (vérifiée plus haut)
    return is_explicit_request(msg.get("content"))


def looks_masked(msg: dict | None, bot_user_id: str | None) -> bool:
    """Message vidé par Discord : sans l'option « Message Content Intent » du
    bot, le texte, les embeds et les pièces jointes des messages des autres (y
    compris ceux de l'appli, postés par le webhook) arrivent vides, et le pont
    ne peut plus reconnaître les demandes."""
    if not msg or msg.get("type", 0) not in (0, 19) or msg.get("pinned"):
        return False
    author = msg.get("author") or {}
    if bot_user_id and str(author.get("id")) == str(bot_user_id):
        return False
    # Autocollant, transfert, sondage… : un message sans texte peut être normal.
    keys = ("content", "embeds", "attachments", "sticker_items", "message_snapshots", "poll", "components")
    return not any(msg.get(k) for k in keys)


def is_app_post(msg: dict) -> bool:
    """Demande envoyée depuis l'appli : un embed avec le champ « Type »."""
    return any(f.get("name") == "Type" for e in msg.get("embeds") or [] for f in e.get("fields") or [])


def after_cutoff(message_id: str, since_id: str | None) -> bool:
    """Message postérieur à DISCORD_SINCE_ID (les plus anciens sont ignorés :
    tout ce qui a été posté avant la mise en route du bot)."""
    if not since_id:
        return True
    try:
        return int(message_id) > int(since_id)
    except ValueError:
        return True


def needs_thread(msg: dict, bot_user_id: str | None) -> bool:
    """Demande qui n'a pas encore de fil : le bot doit en ouvrir un dessous."""
    has_thread = msg.get("thread") or int(msg.get("flags") or 0) & HAS_THREAD_FLAG
    return is_request_message(msg, bot_user_id) and not has_thread


def first_line(text: str) -> str:
    """Première ligne non vide, sans mentions ni mise en forme Discord."""
    for line in (text or "").splitlines():
        line = re.sub(r"<a?(:\w+:)\d+>", r"\1", line)  # émoji perso → :nom:
        line = re.sub(r"<(?:@[!&]?|#)\d+>", "", line)  # mentions, salons
        line = re.sub(r"^\s*(?:#{1,3}|>{1,3}|[-*•])\s+", "", line)  # titre, citation, puce
        line = re.sub(r"\*\*|__|~~|\|\||`", "", line)
        line = " ".join(line.split())
        if line:
            return line
    return ""


def shorten(text: str, limit: int) -> str:
    """Coupe à `limit` caractères, entre deux mots si possible, avec « … »."""
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    if not text[limit - 1].isspace() and " " in cut[limit // 2:]:
        cut = cut[: cut.rindex(" ")]  # pas de mot coupé en deux
    return cut.rstrip(" ,;:.!?-–—") + "…"


def thread_title(msg: dict) -> str:
    """Nom du fil ouvert sous une demande d'un salon texte : 1re ligne du message
    écrit à la main, sinon titre de l'embed de l'appli sans « 💡 Idée : »."""
    candidates = [msg.get("content") or ""]
    for e in msg.get("embeds") or []:
        candidates.append(KIND_PREFIX_RE.sub("", e.get("title") or "", count=1))
        candidates.append(e.get("description") or "")
    for text in candidates:
        line = first_line(text)
        if line:
            return shorten(line, THREAD_NAME_MAX)
    author = msg.get("author") or {}
    name = author.get("global_name") or author.get("username") or "un pote"
    return shorten(f"Demande de {name}", THREAD_NAME_MAX)


def describe_starter(starter: dict | None) -> tuple[str, str, list[str], str | None]:
    """(auteur, texte, infos techniques, image) depuis le premier message."""
    if not starter:
        return ("inconnu", "_(message introuvable)_", [], None)
    author = starter.get("author", {}).get("global_name") or starter.get("author", {}).get("username") or "inconnu"
    text = starter.get("content", "").strip()
    infos: list[str] = []
    image = None
    for e in starter.get("embeds", []):
        if e.get("description"):
            text = (text + "\n\n" + e["description"]).strip()
        for f in e.get("fields", []):
            name, value = f.get("name", ""), f.get("value", "")
            if name == "De la part de":
                author = value
            elif name in ("Appli", "Téléphone"):
                infos.append(f"{name} : {value}")
        image = (e.get("image") or {}).get("url") or image
    for a in starter.get("attachments", []):
        if (a.get("content_type") or "").startswith("image/"):
            image = image or a.get("url")
    return (author, text or "_(pas de texte)_", infos, image)


def gh_safe(text: str) -> str:
    """Neutralise les @mentions : un « @marc » écrit sur Discord ne doit pas
    notifier un inconnu sur GitHub."""
    return re.sub(r"@(?=[\w-])", "@\u200b", text)


def issue_body(thread: dict, starter: dict | None, guild_id: str, votes: int) -> str:
    author, text, infos, image = describe_starter(starter)
    link = f"https://discord.com/channels/{guild_id}/{thread['id']}"
    lines = [
        gh_safe(text),
        "",
        "---",
        f"**De :** {gh_safe(author)}  ",
        f"**Discord :** [ouvrir le fil]({link})",
        f"**👍 Votes :** {votes}",
    ]
    if infos:
        lines.append("")
        lines.extend(f"- {i}" for i in infos)
    if image:
        lines += ["", f"![capture]({image})"]
    lines += ["", f"<!-- {THREAD_MARKER}:{thread['id']} -->"]
    return "\n".join(lines)


def thread_id_of(issue: dict) -> str | None:
    m = re.search(rf"<!-- {THREAD_MARKER}:(\d+) -->", issue.get("body") or "")
    return m.group(1) if m else None


def posted_ids(body: str) -> set[str]:
    m = re.search(rf"<!-- {POSTED_MARKER}:([\d,]*) -->", body or "")
    return set(filter(None, m.group(1).split(","))) if m else set()


def with_posted(body: str, ids: set[str]) -> str:
    marker = f"<!-- {POSTED_MARKER}:{','.join(sorted(ids))} -->"
    if re.search(rf"<!-- {POSTED_MARKER}:[\d,]* -->", body):
        return re.sub(rf"<!-- {POSTED_MARKER}:[\d,]* -->", marker, body)
    return body.rstrip() + "\n" + marker


def with_votes(body: str, votes: int) -> str:
    return VOTES_RE.sub(f"**👍 Votes :** {votes}", body)


def seen_id(body: str, thread_id: str) -> str:
    """Dernier message du fil déjà recopié (le premier message par défaut)."""
    m = re.search(rf"<!-- {SEEN_MARKER}:(\d+) -->", body or "")
    return m.group(1) if m else thread_id


def with_seen(body: str, message_id: str) -> str:
    marker = f"<!-- {SEEN_MARKER}:{message_id} -->"
    if re.search(rf"<!-- {SEEN_MARKER}:\d+ -->", body):
        return re.sub(rf"<!-- {SEEN_MARKER}:\d+ -->", marker, body)
    return body.rstrip() + "\n" + marker


def replies_to_copy(messages: list[dict], thread_id: str) -> list[dict]:
    """Messages des potes à recopier, du plus ancien au plus récent : ni le
    premier message, ni ceux du bot ou d'un webhook (réponses déjà sur GitHub)."""
    keep = [
        m for m in messages
        if m.get("id") != thread_id
        and not m.get("webhook_id")
        and not (m.get("author") or {}).get("bot")
        and m.get("type", 0) in (0, 19)
    ]
    return sorted(keep, key=lambda m: int(m["id"]))


def reply_comment(message: dict) -> str:
    author = (message.get("author") or {})
    name = author.get("global_name") or author.get("username") or "inconnu"
    lines = [f"**💬 {gh_safe(name)} sur Discord :**", ""]
    text = (message.get("content") or "").strip()
    if text:
        lines.append("\n".join("> " + l for l in gh_safe(text).splitlines()))
    for a in message.get("attachments", []):
        if (a.get("content_type") or "").startswith("image/"):
            lines += ["", f"![capture]({a.get('url')})"]
    lines += ["", f"<!-- {MESSAGE_MARKER}:{message['id']} -->"]
    return "\n".join(lines)


def relayable(comment: dict) -> bool:
    """Commentaire GitHub à reposter dans le fil Discord."""
    return REPLY_MARKER in (comment.get("body") or "") and comment.get("author_association") in TRUSTED_AUTHORS


def discord_text(comment_body: str) -> str:
    """Commentaire GitHub → message Discord (sans marqueurs ni pied de page)."""
    text = comment_body.replace(REPLY_MARKER, "")
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"\n-{3,}\n_Generated by \[Claude Code\].*$", "", text, flags=re.S)
    text = text.strip()
    return text[:1900] + ("…" if len(text) > 1900 else "")


def closing_message(issue: dict) -> str:
    if issue.get("state_reason") == "not_planned":
        return "🙏 On ne va pas le faire pour l'instant. Merci quand même pour l'idée, elle reste notée !"
    return "✅ C'est fait ! Ce sera dans la prochaine version de l'appli (lien « derniere-version »). Merci 🙌"


# ---------------------------------------------------------------------------
# Accès réseau
# ---------------------------------------------------------------------------


class Http:
    def __init__(self, base: str, headers: dict[str, str]):
        self.base = base
        self.headers = headers

    def call(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(4):
            req = urllib.request.Request(self.base + path, data=data, method=method)
            for k, v in self.headers.items():
                req.add_header(k, v)
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < 3:
                    retry = 2.0
                    try:
                        retry = float(json.loads(e.read() or b"{}").get("retry_after", 2))
                    except Exception:
                        pass
                    time.sleep(min(retry, 30) + 0.5)
                    continue
                raise RuntimeError(f"{method} {path} → {e.code} {e.read()[:300]!r}") from e
        return None


def main() -> int:
    token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
    salon = channel_id_from(os.environ)
    since = os.environ.get("DISCORD_SINCE_ID", "").strip() or None
    gh_token = os.environ.get("GITHUB_TOKEN", "").strip()
    repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if not token or not salon:
        print("::notice::DISCORD_BOT_TOKEN / DISCORD_FORUM_CHANNEL_ID (ou DISCORD_CHANNEL_ID) absents :"
              " synchro Discord ignorée.")
        return 0
    if not gh_token or not repo:
        print("::error::GITHUB_TOKEN / GITHUB_REPOSITORY manquants.")
        return 1

    discord = Http(DISCORD_API, {"Authorization": f"Bot {token}", "User-Agent": USER_AGENT})
    github = Http(
        GITHUB_API,
        {
            "Authorization": f"Bearer {gh_token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": USER_AGENT,
        },
    )

    channel = discord.call("GET", f"/channels/{salon}")
    guild_id = channel["guild_id"]
    text_mode = is_text_channel(channel)
    forum_tags = {t["id"]: t.get("name", "") for t in channel.get("available_tags", [])}

    # Étiquettes GitHub
    existing_labels = {l["name"] for l in github.call("GET", f"/repos/{repo}/labels?per_page=100")}
    for name, (color, desc) in LABELS.items():
        if name not in existing_labels:
            github.call("POST", f"/repos/{repo}/labels", {"name": name, "color": color, "description": desc})

    # Tickets déjà créés
    issues: list[dict] = []
    page = 1
    while True:
        batch = github.call("GET", f"/repos/{repo}/issues?labels=feedback&state=all&per_page=100&page={page}")
        issues += [i for i in batch if "pull_request" not in i]
        if len(batch) < 100:
            break
        page += 1
    by_thread = {tid: i for i in issues if (tid := thread_id_of(i))}

    created = copied = errors = opened = 0
    threads: list[dict] = []
    bot_id = None
    if text_mode:
        # Salon texte : un fil sous chaque nouvelle demande (parmi les 100 derniers
        # messages). Le fil prend l'id du message. Une demande qui a déjà un ticket
        # n'en reçoit pas d'autre (fil supprimé par un modo, par exemple).
        bot_id = (discord.call("GET", "/users/@me") or {}).get("id")
        recent = discord.call("GET", f"/channels/{salon}/messages?limit=100") or []
        masked = [m for m in recent if after_cutoff(m["id"], since) and looks_masked(m, bot_id)]
        if masked:
            # Sinon le pont ignorerait ces demandes sans rien dire.
            errors += 1
            print(f"::error::{len(masked)} message(s) du salon arrivent vides : active « Message Content Intent » "
                  "(portail développeur Discord › ton appli › Bot › Privileged Gateway Intents › Save Changes).")
        for m in sorted(recent, key=lambda m: int(m["id"])):
            if m["id"] in by_thread or not after_cutoff(m["id"], since) or not needs_thread(m, bot_id):
                continue
            name = thread_title(m)
            try:
                t = discord.call("POST", f"/channels/{salon}/messages/{m['id']}/threads",
                                 {"name": name, "auto_archive_duration": 10080})
            except RuntimeError as e:
                errors += 1
                print(f"::warning::Impossible d'ouvrir un fil sous le message {m['id']} : {e}")
                continue
            threads.append(t or {"id": m["id"], "name": name, "parent_id": salon})
            opened += 1

    threads += [t for t in discord.call("GET", f"/guilds/{guild_id}/threads/active").get("threads", [])
                if t.get("parent_id") == salon]
    archived = discord.call("GET", f"/channels/{salon}/threads/archived/public?limit=50") or {}
    threads += archived.get("threads", [])
    unique: dict[str, dict] = {}
    for t in threads:
        unique.setdefault(t["id"], t)
    threads = list(unique.values())

    for t in threads:
        tid = t["id"]
        try:
            # Forum : le 1er message vit dans le fil, avec le même id que lui.
            # Salon texte : il est dans le salon, et le fil porte son id.
            starter_path = f"/channels/{salon}/messages/{tid}" if text_mode else f"/channels/{tid}/messages/{tid}"
            try:
                starter = discord.call("GET", starter_path)
            except RuntimeError:
                starter = None
            votes = votes_of(starter)
            issue = by_thread.get(tid)
            if issue is None:
                if text_mode and (not after_cutoff(tid, since) or not is_request_message(starter, bot_id)):
                    # Fil ouvert à la main sous un message qui n'est pas une demande
                    # (le « Comment ça marche » épinglé…) ou sans message de départ.
                    continue
                kind = kind_of(t, starter, forum_tags)
                prefix = {"bug": "[Bug]", "idée": "[Idée]"}.get(kind, "[Retour]")
                labels = ["feedback"] + ([kind] if kind in LABELS else [])
                issue = github.call("POST", f"/repos/{repo}/issues", {
                    "title": f"{prefix} {clean_title(t.get('name', ''))}"[:250],
                    "body": issue_body(t, starter, guild_id, votes),
                    "labels": labels,
                })
                by_thread[tid] = issue
                created += 1
                try:
                    discord.call("POST", f"/channels/{tid}/messages", {
                        "content": f"📌 Bien reçu ! C'est noté (n°{issue['number']}). On te répond ici dès qu'on l'a regardé.",
                        "allowed_mentions": {"parse": []},
                    })
                except RuntimeError as e:
                    print(f"::warning::Réponse Discord impossible dans le fil {tid} : {e}")

            body = issue.get("body") or ""
            # Votes
            new_body = with_votes(body, votes)
            # Réponses des potes dans le fil → commentaires du ticket
            last = seen_id(new_body, tid)
            try:
                messages = discord.call("GET", f"/channels/{tid}/messages?after={last}&limit=100") or []
            except RuntimeError as e:
                print(f"::warning::Lecture du fil {tid} impossible : {e}")
                messages = []
            for m in replies_to_copy(messages, tid):
                github.call("POST", f"/repos/{repo}/issues/{issue['number']}/comments", {"body": reply_comment(m)})
                copied += 1
            if messages:
                newest = max(messages, key=lambda m: int(m["id"]))["id"]
                if int(newest) > int(last):
                    new_body = with_seen(new_body, newest)
            # Commentaires à relayer sur Discord
            done = posted_ids(new_body)
            comments = github.call("GET", f"/repos/{repo}/issues/{issue['number']}/comments?per_page=100")
            for c in comments:
                cid = str(c["id"])
                if relayable(c) and cid not in done:
                    text = discord_text(c["body"])
                    if text:
                        discord.call("POST", f"/channels/{tid}/messages",
                                     {"content": text, "allowed_mentions": {"parse": []}})
                    done.add(cid)
            if done != posted_ids(new_body):
                new_body = with_posted(new_body, done)
            # Ticket fermé : annonce une seule fois
            if issue.get("state") == "closed" and f"<!-- {NOTIFIED_MARKER} -->" not in new_body:
                discord.call("POST", f"/channels/{tid}/messages",
                             {"content": closing_message(issue), "allowed_mentions": {"parse": []}})
                new_body = new_body.rstrip() + f"\n<!-- {NOTIFIED_MARKER} -->"
            if new_body != body:
                github.call("PATCH", f"/repos/{repo}/issues/{issue['number']}", {"body": new_body})
        except RuntimeError as e:
            # Un fil en erreur ne bloque pas les autres ; il sera repris au prochain passage.
            errors += 1
            print(f"::warning::Fil {tid} : {e}")

    print(f"Salon {'texte' if text_mode else 'forum'} · fils Discord vus : {len(threads)}"
          f" · fils ouverts : {opened} · nouveaux tickets : {created} · réponses recopiées : {copied}"
          f" · erreurs : {errors}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
