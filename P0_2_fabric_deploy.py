#!/usr/bin/env python3
"""
KDD OneLake security · Fabric deployment (Phases 0, 1, 2, 4, 5)

Run as Uma (Fabric administrator) from the folder that holds kdd_ids.env and the notebooks/ folder:
    pip install requests
    az login --tenant <your-tenant>            # same account as Uma
    python P0_2_fabric_deploy.py foundation    # P0: workspaces, capacity, domains, access, lakehouses, SQL database
    python P0_2_fabric_deploy.py notebooks     # P1-P5: import all notebooks with IDs and config filled in
    python P0_2_fabric_deploy.py shortcut      # P2: supplier shortcut (run after NB_AP_Conform has run once)
    python P0_2_fabric_deploy.py pipeline      # P5: PL_SEC_Lifecycle + daily 06:00 Kuwait schedule
    python P0_2_fabric_deploy.py run           # P5: start PL_SEC_Lifecycle now (same call Power Automate makes)
Every command is re-runnable; existing items are reused or updated. IDs are written to kdd_fabric_ids.json.
"""
import base64, json, os, subprocess, sys, time, pathlib
import requests

HERE = pathlib.Path(__file__).resolve().parent
API = "https://api.fabric.microsoft.com/v1"
ENV = dict(l.strip().split("=", 1) for l in (HERE / "kdd_ids.env").read_text().splitlines() if "=" in l)
IDS_FILE = HERE / "kdd_fabric_ids.json"
IDS = json.loads(IDS_FILE.read_text()) if IDS_FILE.exists() else {}
MAIL_SENDER = os.environ.get("KDD_MAIL_SENDER", ENV["ADMIN_UPN"])
SECURITY_MAIL = os.environ.get("KDD_SECURITY_MAIL", ENV["ADMIN_UPN"])

WORKSPACES = {   # name: (domain, layer)
    "WS-PRC-Bronze": ("Procurement", "Bronze"), "WS-PRC-Silver": ("Procurement", "Silver"), "WS-PRC-Gold": ("Procurement", "Gold"),
    "WS-AP-Bronze": ("Payables", "Bronze"), "WS-AP-Silver": ("Payables", "Silver"), "WS-AP-Gold": ("Payables", "Gold"),
    "WS-SEC-Control": (None, "Control"),
}
LAKEHOUSES = {"LH_PRC_Bronze": "WS-PRC-Bronze", "LH_PRC_Silver": "WS-PRC-Silver", "LH_PRC_Gold": "WS-PRC-Gold",
              "LH_AP_Bronze": "WS-AP-Bronze", "LH_AP_Silver": "WS-AP-Silver", "LH_AP_Gold": "WS-AP-Gold"}
# Workspace roles from design section 4.5 (business groups grp-ol-* are added later by NB_SEC_Sync)
RBAC = {
    "GRP_SEC_ADMINS": ("Group", {w: "Admin" for w in WORKSPACES}),
    "SP_OID": ("ServicePrincipal", {**{w: "Member" for w in WORKSPACES if w != "WS-SEC-Control"}, "WS-SEC-Control": "Admin"}),
    "GRP_DATA_ENG": ("Group", {"WS-PRC-Bronze": "Contributor", "WS-PRC-Silver": "Contributor", "WS-PRC-Gold": "Viewer",
                               "WS-AP-Bronze": "Contributor", "WS-AP-Silver": "Contributor", "WS-AP-Gold": "Viewer"}),
    "GRP_BI_DEV": ("Group", {"WS-PRC-Gold": "Contributor", "WS-AP-Gold": "Contributor"}),
}
NOTEBOOKS = [  # (notebook name, workspace, source file, extra placeholders)
    ("NB_PRC_Load", "WS-PRC-Bronze", "nb_bronze", {"DOM": "PRC", "LH": "LH_PRC_Bronze"}),
    ("NB_AP_Load", "WS-AP-Bronze", "nb_bronze", {"DOM": "AP", "LH": "LH_AP_Bronze"}),
    ("NB_PRC_Conform", "WS-PRC-Silver", "nb_prc_conform", {}),
    ("NB_AP_Conform", "WS-AP-Silver", "nb_ap_conform", {}),
    ("NB_PRC_Gold", "WS-PRC-Gold", "nb_gold", {"DOM": "PRC", "LH": "LH_PRC_Gold", "OWN": "PRC"}),
    ("NB_AP_Gold", "WS-AP-Gold", "nb_gold", {"DOM": "AP", "LH": "LH_AP_Gold", "OWN": "AP"}),
    ("NB_SEC_Common", "WS-SEC-Control", "nb_sec_common", {}),
    ("NB_SEC_Lifecycle", "WS-SEC-Control", "nb_sec_lifecycle", {}),
    ("NB_SEC_Sync", "WS-SEC-Control", "nb_sec_sync", {}),
    ("NB_SEC_Notify", "WS-SEC-Control", "nb_sec_notify", {}),
    ("NB_SEC_Run", "WS-SEC-Control", "nb_sec_run", {}),
]

_tok = {}
def token():
    if not _tok or _tok["exp"] < time.time() + 120:
        out = subprocess.check_output(["az", "account", "get-access-token", "--resource", "https://api.fabric.microsoft.com", "-o", "json"], shell=(os.name == "nt"))
        j = json.loads(out); _tok.update(t=j["accessToken"], exp=time.time() + 3000)
    return _tok["t"]

def call(method, path, ok=(200, 201, 202), **kw):
    url = path if path.startswith("http") else API + path
    for attempt in range(8):
        r = requests.request(method, url, headers={"Authorization": f"Bearer {token()}"}, **kw)
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(int(r.headers.get("Retry-After", 2 ** attempt))); continue
        if ok and r.status_code not in ok:
            raise SystemExit(f"{method} {url} -> {r.status_code}\n{r.text[:800]}")
        if r.status_code == 202 and "Location" in r.headers and method != "GET":
            return lro(r)
        return r
    raise SystemExit(f"{method} {url}: too many retries")

def lro(r):
    loc = r.headers["Location"]
    while True:
        time.sleep(int(r.headers.get("Retry-After", 5)))
        r = requests.get(loc, headers={"Authorization": f"Bearer {token()}"})
        st = r.json().get("status") if r.content else None
        if st in ("Succeeded", None):
            res = requests.get(loc.rstrip("/") + "/result", headers={"Authorization": f"Bearer {token()}"})
            return res if res.status_code == 200 else r
        if st == "Failed":
            raise SystemExit(f"Operation failed: {r.text[:800]}")

def all_items(path):
    out, url = [], path
    while url:
        j = call("GET", url).json(); out += j.get("value", j.get("domains", [])); url = j.get("continuationUri")
    return out

def save_ids():
    IDS_FILE.write_text(json.dumps(IDS, indent=2)); print(f"IDs saved to {IDS_FILE.name}")

def ensure_item(ws_name, kind, name, body):
    wid = IDS["workspaces"][ws_name]
    found = [x for x in all_items(f"/workspaces/{wid}/{kind}") if x["displayName"] == name]
    if found:
        return found[0]["id"], False
    res = call("POST", f"/workspaces/{wid}/{kind}", json={"displayName": name, **body})
    j = res.json() if res.content else {}
    iid = j.get("id") or [x for x in all_items(f"/workspaces/{wid}/{kind}") if x["displayName"] == name][0]["id"]
    print(f"Created {kind[:-1]} {name}")
    return iid, True

# ----------------------------------------------------------------------------- P0
def foundation():
    allcaps = all_items("/capacities")
    caps = [c for c in allcaps if c["displayName"].lower() == ENV["CAPACITY_NAME"].lower()]
    if not caps:  # free trial: fall back to the single active trial capacity (SKU FT1)
        caps = [c for c in allcaps if str(c.get("sku", "")).upper().startswith("FT") and c.get("state", "Active") == "Active"]
        if len(caps) == 1:
            print(f"Using trial capacity '{caps[0]['displayName']}'")
        else:
            caps = []
    if not caps:
        print("Capacities visible to you:", [c["displayName"] for c in all_items("/capacities")])
        raise SystemExit(f"Capacity '{ENV['CAPACITY_NAME']}' not found. Create it or set CAPACITY_NAME in kdd_ids.env to a listed name.")
    cap = caps[0]["id"]
    IDS.setdefault("workspaces", {})
    existing = {w["displayName"]: w["id"] for w in all_items("/workspaces")}
    for name, (dom, layer) in WORKSPACES.items():
        if name in existing:
            IDS["workspaces"][name] = existing[name]
        else:
            IDS["workspaces"][name] = call("POST", "/workspaces", json={"displayName": name, "capacityId": cap,
                                           "description": f"KDD {dom or 'Security'} {layer}"}).json()["id"]
            print("Created workspace", name)
        call("POST", f"/workspaces/{IDS['workspaces'][name]}/assignToCapacity", ok=(200, 202), json={"capacityId": cap})
    # domains (Fabric admin API)
    doms = {d["displayName"]: d["id"] for d in all_items("/admin/domains")}
    for dname in ("Procurement", "Payables"):
        if dname not in doms:
            doms[dname] = call("POST", "/admin/domains", json={"displayName": dname, "description": f"KDD {dname} data domain"}).json()["id"]
            print("Created domain", dname)
        wss = [IDS["workspaces"][w] for w, (d, _) in WORKSPACES.items() if d == dname]
        call("POST", f"/admin/domains/{doms[dname]}/assignWorkspaces", ok=(200, 202), json={"workspacesIds": wss})
    IDS["domains"] = doms
    # workspace roles
    for key, (ptype, mapping) in RBAC.items():
        pid = ENV[key]
        for ws, role in mapping.items():
            wid = IDS["workspaces"][ws]
            have = {a["principal"]["id"]: a for a in all_items(f"/workspaces/{wid}/roleAssignments")}
            if pid not in have:
                call("POST", f"/workspaces/{wid}/roleAssignments", json={"principal": {"id": pid, "type": ptype}, "role": role})
                print(f"{key} -> {role} on {ws}")
            elif have[pid]["role"] != role:
                call("PATCH", f"/workspaces/{wid}/roleAssignments/{have[pid]['id']}", json={"role": role})
    # lakehouses with schemas, SQL database
    IDS.setdefault("lakehouses", {})
    for lh, ws in LAKEHOUSES.items():
        IDS["lakehouses"][lh] = ensure_item(ws, "lakehouses", lh, {"creationPayload": {"enableSchemas": True}})[0]
    sid, _ = ensure_item("WS-SEC-Control", "sqlDatabases", "SQLDB_SecMeta", {"description": "KDD OneLake security metamodel"})
    props = call("GET", f"/workspaces/{IDS['workspaces']['WS-SEC-Control']}/sqlDatabases/{sid}").json().get("properties", {})
    IDS["sql"] = {"id": sid, "server": props.get("serverFqdn", "").split(",")[0], "database": props.get("databaseName", "")}
    save_ids()
    print("\nPhase 0 Fabric setup complete. Next: run P3_metamodel.sql in SQLDB_SecMeta, then `python P0_2_fabric_deploy.py notebooks`.")

# ----------------------------------------------------------------------------- notebooks
def placeholders(extra):
    w, l = IDS["workspaces"], IDS["lakehouses"]
    own = extra.get("OWN")
    p = {"TENANT_ID": ENV["TENANT_ID"], "CLIENT_ID": ENV["APP_ID"], "KEY_VAULT_URL": ENV["KEY_VAULT_URL"],
         "SQL_SERVER": IDS["sql"]["server"], "SQL_DATABASE": IDS["sql"]["database"], "MAIL_SENDER": MAIL_SENDER,
         "SECURITY_MAIL": SECURITY_MAIL, "TENANT_DOMAIN": ENV["TENANT_DOMAIN"],
         "WS_PRC_BRONZE": w["WS-PRC-Bronze"], "LH_PRC_BRONZE": l["LH_PRC_Bronze"], "WS_AP_BRONZE": w["WS-AP-Bronze"], "LH_AP_BRONZE": l["LH_AP_Bronze"],
         "WS_AP_SILVER": w["WS-AP-Silver"], "LH_AP_SILVER": l["LH_AP_Silver"]}
    if own:
        p.update({"WS_OWN_SILVER": w[f"WS-{own}-Silver"], "LH_OWN_SILVER": l[f"LH_{own}_Silver"],
                  "WS_OWN_BRONZE": w[f"WS-{own}-Bronze"], "LH_OWN_BRONZE": l[f"LH_{own}_Bronze"]})
    p.update(extra)
    return p

def notebooks():
    IDS.setdefault("notebooks", {})
    for name, ws, src, extra in NOTEBOOKS:
        nb = json.loads((HERE / "notebooks" / f"{src}.ipynb").read_text(encoding="utf8"))
        text = json.dumps(nb)
        for k, v in placeholders(extra).items():
            text = text.replace("{{" + k + "}}", str(v))
        assert "{{" not in text.replace("{{{", ""), f"unfilled placeholder in {name}"
        definition = {"format": "ipynb", "parts": [{"path": "artifact.content.ipynb", "payload": base64.b64encode(text.encode()).decode(), "payloadType": "InlineBase64"}]}
        wid = IDS["workspaces"][ws]
        found = [x for x in all_items(f"/workspaces/{wid}/notebooks") if x["displayName"] == name]
        if found:
            call("POST", f"/workspaces/{wid}/notebooks/{found[0]['id']}/updateDefinition", json={"definition": definition})
            IDS["notebooks"][name] = found[0]["id"]; print("Updated", name)
        else:
            res = call("POST", f"/workspaces/{wid}/notebooks", json={"displayName": name, "definition": definition})
            IDS["notebooks"][name] = (res.json() if res.content else {}).get("id") or \
                [x for x in all_items(f"/workspaces/{wid}/notebooks") if x["displayName"] == name][0]["id"]
            print("Imported", name)
    save_ids()

# ----------------------------------------------------------------------------- P2 shortcut
def shortcut():
    prc_ws, prc_lh = IDS["workspaces"]["WS-PRC-Silver"], IDS["lakehouses"]["LH_PRC_Silver"]
    body = {"path": "Tables/silver", "name": "supplier",
            "target": {"oneLake": {"workspaceId": IDS["workspaces"]["WS-AP-Silver"], "itemId": IDS["lakehouses"]["LH_AP_Silver"], "path": "Tables/silver/supplier"}}}
    r = call("POST", f"/workspaces/{prc_ws}/items/{prc_lh}/shortcuts?shortcutConflictPolicy=CreateOrOverwrite", ok=(200, 201), json=body)
    print("Shortcut LH_PRC_Silver/Tables/silver/supplier ->", r.status_code)

# ----------------------------------------------------------------------------- P5 pipeline
def pipeline():
    ws = IDS["workspaces"]["WS-SEC-Control"]; nb = IDS["notebooks"]
    def act(name, nbname, after=None, params=None):
        a = {"name": name, "type": "TridentNotebook", "dependsOn": [{"activity": after, "dependencyConditions": ["Succeeded"]}] if after else [],
             "policy": {"timeout": "0.01:00:00", "retry": 1, "retryIntervalInSeconds": 120},
             "typeProperties": {"notebookId": nb[nbname], "workspaceId": ws}}
        if params: a["typeProperties"]["parameters"] = {k: {"value": v, "type": "string"} for k, v in params.items()}
        return a
    content = {"properties": {"activities": [act("Lifecycle", "NB_SEC_Lifecycle"), act("Sync", "NB_SEC_Sync", "Lifecycle", {"TRIGGER": "Scheduled"}),
                                             act("Notify", "NB_SEC_Notify", "Sync")]}}
    definition = {"parts": [{"path": "pipeline-content.json", "payload": base64.b64encode(json.dumps(content).encode()).decode(), "payloadType": "InlineBase64"}]}
    found = [x for x in all_items(f"/workspaces/{ws}/dataPipelines") if x["displayName"] == "PL_SEC_Lifecycle"]
    if found:
        pid = found[0]["id"]; call("POST", f"/workspaces/{ws}/dataPipelines/{pid}/updateDefinition", json={"definition": definition})
    else:
        res = call("POST", f"/workspaces/{ws}/dataPipelines", json={"displayName": "PL_SEC_Lifecycle", "definition": definition})
        pid = (res.json() if res.content else {}).get("id") or [x for x in all_items(f"/workspaces/{ws}/dataPipelines") if x["displayName"] == "PL_SEC_Lifecycle"][0]["id"]
    IDS["pipeline"] = pid; save_ids(); print("PL_SEC_Lifecycle ready:", pid)
    sched = {"enabled": True, "configuration": {"type": "Daily", "times": ["06:00"], "startDateTime": time.strftime("%Y-%m-%dT00:00:00Z"),
                                                "endDateTime": "2027-12-31T23:59:00Z", "localTimeZoneId": "Arab Standard Time"}}
    for job_type in ("Pipeline", "DefaultJob"):
        have = call("GET", f"/workspaces/{ws}/items/{pid}/jobs/{job_type}/schedules", ok=None)
        if have.status_code == 200 and have.json().get("value"):
            print(f"Schedule already exists (jobType {job_type}); not adding another"); return
        r = call("POST", f"/workspaces/{ws}/items/{pid}/jobs/{job_type}/schedules", ok=None, json=sched)
        if r.status_code in (200, 201):
            print(f"Daily 06:00 (Kuwait time) schedule created with jobType {job_type}"); return
    print("Could not create the schedule through the API: open PL_SEC_Lifecycle > Schedule and set Daily 06:00, (UTC+03:00) Kuwait, Riyadh.")

def run():
    ws = IDS["workspaces"]["WS-SEC-Control"]
    pid = IDS.get("pipeline") or next((x["id"] for x in all_items(f"/workspaces/{ws}/dataPipelines") if x["displayName"] == "PL_SEC_Lifecycle"), None)
    if not pid: sys.exit("PL_SEC_Lifecycle not found: run `python P0_2_fabric_deploy.py pipeline` first")
    IDS["pipeline"] = pid; save_ids()
    r = call("POST", f"/workspaces/{ws}/items/{pid}/jobs/instances?jobType=Pipeline", ok=(202,))
    print("Started PL_SEC_Lifecycle:", r.headers.get("Location"))

if __name__ == "__main__":
    {"foundation": foundation, "notebooks": notebooks, "shortcut": shortcut, "pipeline": pipeline, "run": run}[sys.argv[1] if len(sys.argv) > 1 else "foundation"]()
