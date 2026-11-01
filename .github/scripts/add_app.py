import base64
import json
import os
import re
import urllib.error
import urllib.request


API = "https://api.github.com"
REPOSITORY = os.environ["GH_REPOSITORY"]
TOKEN = os.environ["GH_TOKEN"]
ISSUE_NUMBER = os.environ["ISSUE_NUMBER"]
BODY = os.environ["ISSUE_BODY"]
ALLOWED_ASSOCIATIONS = {"OWNER", "COLLABORATOR", "MEMBER"}
ID_PATTERN = re.compile(r"^(?:[A-Za-z0-9][A-Za-z0-9._+{}-]*|\{[0-9A-Fa-f-]{20,}\})$")
APPX_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ALLOWED_ROOTS = {"LocalAppData", "RoamingAppData", "ProgramData", "ProgramFiles", "ProgramFilesX86"}


def api_request(method, path, payload=None):
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {TOKEN}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "windows-app-list",
            **({"Content-Type": "application/json"} if data is not None else {}),
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def section(label):
    match = re.search(
        rf"^### {re.escape(label)}\s*\r?\n(.*?)(?=^### |\Z)",
        BODY,
        flags=re.MULTILINE | re.DOTALL,
    )
    if not match:
        return ""
    value = match.group(1).strip()
    return "" if value in {"_No response_", ""} else value


def fail(message):
    raise SystemExit(message)


def main():
    event_path = os.environ["GITHUB_EVENT_PATH"]
    with open(event_path, encoding="utf-8") as event_file:
        event = json.load(event_file)
    issue = event["issue"]
    if issue.get("author_association") not in ALLOWED_ASSOCIATIONS:
        fail("Solo el propietario o una persona colaboradora puede actualizar esta lista.")

    name = section("Nombre de la app")
    winget_id = section("ID de WinGet")
    appx_text = section("Nombres de paquetes Appx")
    residues_text = section("Rutas de residuos")
    confirmation = section("Confirmación")

    if not name or len(name) > 100 or "\n" in name or "\r" in name:
        fail("Escribe un nombre de app válido (máximo 100 caracteres).")
    if not winget_id and not appx_text:
        fail("Indica al menos un ID de WinGet o un nombre Appx exacto.")
    if not re.search(r"(?im)^\s*-\s*\[x\]\s*Confirmo que estos identificadores y rutas corresponden a esta app\.", confirmation):
        fail("Marca la casilla de confirmación del formulario.")
    if winget_id and not ID_PATTERN.fullmatch(winget_id):
        fail("El ID de WinGet contiene caracteres no permitidos.")

    appx_names = []
    for value in appx_text.splitlines():
        value = value.strip()
        if value and value != "_No response_":
            if not APPX_PATTERN.fullmatch(value):
                fail(f"Nombre Appx no válido: {value}")
            if value not in appx_names:
                appx_names.append(value)

    residual_paths = []
    for value in residues_text.splitlines():
        value = value.strip()
        if not value or value == "_No response_":
            continue
        if value.count("/") < 1:
            fail(f"Ruta no válida: {value}. Usa Raiz/carpeta/archivo.")
        root, relative = value.split("/", 1)
        segments = relative.split("/")
        if root not in ALLOWED_ROOTS or any(part in {"", ".", ".."} for part in segments):
            fail(f"Ruta no permitida: {value}")
        if any(not re.fullmatch(r"[A-Za-z0-9 _().+-]+", part) for part in segments):
            fail(f"Ruta contiene caracteres no permitidos: {value}")
        item = {"root": root, "path": "/".join(segments)}
        if item not in residual_paths:
            residual_paths.append(item)

    repo = api_request("GET", f"/repos/{REPOSITORY}")
    branch = repo["default_branch"]
    encoded_path = urllib.parse.quote("apps.json", safe="")
    file_info = api_request("GET", f"/repos/{REPOSITORY}/contents/{encoded_path}?ref={urllib.parse.quote(branch, safe='')}")
    current_bytes = base64.b64decode(file_info["content"])
    manifest = json.loads(current_bytes.decode("utf-8"))
    apps = manifest.get("apps")
    if not isinstance(apps, list):
        fail("apps.json no contiene la lista esperada.")
    for app in apps:
        if app.get("name", "").casefold() == name.casefold():
            fail(f"Ya existe una app llamada {name}.")
        if winget_id and app.get("wingetId", "").casefold() == winget_id.casefold():
            fail(f"El ID de WinGet {winget_id} ya está en la lista.")

    new_app = {"name": name}
    if winget_id:
        new_app["wingetId"] = winget_id
    if appx_names:
        new_app["appxNames"] = appx_names
    if residual_paths:
        new_app["residualPaths"] = residual_paths
    apps.append(new_app)
    updated = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

    api_request(
        "PUT",
        f"/repos/{REPOSITORY}/contents/{encoded_path}",
        {
            "message": f"Agregar {name} a la lista",
            "content": base64.b64encode(updated).decode("ascii"),
            "sha": file_info["sha"],
            "branch": branch,
        },
    )
    api_request(
        "POST",
        f"/repos/{REPOSITORY}/issues/{ISSUE_NUMBER}/comments",
        {"body": f"Se agregó **{name}** a `apps.json`. Ya aparece en la lista web."},
    )
    api_request("PATCH", f"/repos/{REPOSITORY}/issues/{ISSUE_NUMBER}", {"state": "closed"})


if __name__ == "__main__":
    import urllib.parse

    try:
        main()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        fail(f"GitHub rechazó la actualización (HTTP {error.code}): {detail[:500]}")
