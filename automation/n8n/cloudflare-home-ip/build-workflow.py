"""Build an inactive n8n workflow with the tested validation logic embedded."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent
logic = (root / "logic.js").read_text().split("if (typeof module")[0]
base = "='https://api.cloudflare.com/client/v4/accounts/' + $('Config').first().json.account_id + '/access/groups/' + $('Config').first().json.group_id"
# n8n expressions use {{ }} delimiters, with = outside the expression.
url = "={{ " + base[1:] + " }}"


def node(name, kind, parameters, x, y=0, version=1):
    return {"id": name.lower().replace(" ", "-"), "name": name, "type": "n8n-nodes-base." + kind,
            "typeVersion": version, "position": [x, y], "parameters": parameters}


def http_group(name, x, method="GET"):
    parameters = {"url": url, "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
                  "options": {"timeout": 15000, "redirect": {"redirect": {"followRedirects": False}}}}
    if method == "PUT":
        parameters.update({"method": "PUT", "sendBody": True, "specifyBody": "json",
                           "jsonBody": "={{ $('Prepare').first().json.payload }}"})
    return node(name, "httpRequest", parameters, x, version=4.2)


nodes = [
    node("Manual Trigger", "manualTrigger", {}, 0),
    node("Every five minutes", "scheduleTrigger", {"rule": {"interval": [{"field": "minutes", "minutesInterval": 5}]}}, 0, 180, 1.2),
    node("Config", "code", {"jsCode": "return [{json: {account_id: '', group_id: '', group_name: 'homelab-dynamic-home-ip', dry_run: true}}];"}, 220, version=2),
    node("Validate config", "code", {"jsCode": logic + "\nvalidateConfig($input.first().json); return $input.all();"}, 440, version=2),
    node("Public IP A", "httpRequest", {"url": "https://api.ipify.org?format=json", "options": {"timeout": 15000}}, 660, version=4.2),
    node("Public IP B", "httpRequest", {"url": "https://ipv4.icanhazip.com", "options": {"timeout": 15000, "response": {"response": {"responseFormat": "text"}}}}, 880, version=4.2),
    http_group("Read dedicated group", 1100),
    node("Prepare", "code", {"jsCode": logic + "\nreturn [{json: prepare($('Config').first().json, $('Public IP A').first().json.ip, $('Public IP B').first().json.data, $input.first().json)}];"}, 1320, version=2),
    node("Write permitted", "if", {"conditions": {"options": {"caseSensitive": True, "typeValidation": "strict", "version": 2},
         "conditions": [{"id": "write", "leftValue": "={{ $json.should_update }}", "rightValue": "", "operator": {"type": "boolean", "operation": "true", "singleValue": True}}], "combinator": "and"}}, 1540, version=2.2),
    http_group("Update dedicated group", 1760, "PUT"),
    http_group("Read back", 1980),
    node("Verify", "code", {"jsCode": logic + "\nreturn [{json: verify($('Config').first().json, $('Prepare').first().json, $input.first().json)}];"}, 2200, version=2),
    node("Dry run or unchanged", "code", {"jsCode": "const p=$input.first().json; return [{json:{changed:p.changed,dry_run:p.dry_run,updated:false}}];"}, 1760, 200, 2),
]
connections = {}
for a, b in [("Manual Trigger", "Config"), ("Every five minutes", "Config"), ("Config", "Validate config"),
             ("Validate config", "Public IP A"), ("Public IP A", "Public IP B"), ("Public IP B", "Read dedicated group"),
             ("Read dedicated group", "Prepare"), ("Prepare", "Write permitted"),
             ("Update dedicated group", "Read back"), ("Read back", "Verify")]:
    connections[a] = {"main": [[{"node": b, "type": "main", "index": 0}]]}
connections["Write permitted"] = {"main": [[{"node": "Update dedicated group", "type": "main", "index": 0}],
                                          [{"node": "Dry run or unchanged", "type": "main", "index": 0}]]}
workflow = {"name": "Cloudflare - dedicated home IPv4 group", "active": False, "nodes": nodes,
            "connections": connections,
            "settings": {"executionOrder": "v1", "timezone": "Europe/Amsterdam", "executionTimeout": 120,
                         "saveDataSuccessExecution": "none", "saveDataErrorExecution": "none", "saveManualExecutions": False},
            "pinData": {}}
(root / "workflow.json").write_text(json.dumps(workflow, indent=2) + "\n")
