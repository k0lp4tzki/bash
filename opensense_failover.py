#!/usr/bin/env python3
"""
OPNsense HA Failover Script für Fritzbox Port-Forwarding
Gefixt + neu aufgebaut:
- Korrekte TR-064 URNs
- Richtiger Service-Pfad
- Forwarding auf OPNsense-WAN-IP statt internes Netz
- Cleaner Logging + weniger AVM-Fehler
"""

import requests
from requests.auth import HTTPDigestAuth
import time
import xml.etree.ElementTree as ET
import logging
import subprocess
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ----------------------------------------------------------------------
# FRITZBOX KONFIG
# ----------------------------------------------------------------------

FRITZBOX_IP = "192.168.178.1"


# FIXED + OFFIZIELL FUNKTIONIEREND:
FRITZ_WAN_SERVICE_TYPE = "urn:dslforum-org:service:WANIPConnection:1"
FRITZ_WAN_SERVICE_PATH = "/upnp/control/wanipconnection1"

# ----------------------------------------------------------------------
# OPNsense Nodes
# ----------------------------------------------------------------------
OPNSENSE_NODES = {
    "10.1.1.3": {
        "wan_ip": "192.168.178.3",
        "hostname": "PC-192-178-3",
        "ports": []
    },
    "10.1.1.4": {
        "wan_ip": "192.168.178.4",
        "hostname": "PC-192-178-4",
        "ports": []
    }
}

# Diese Ports sollen geschwenkt werden
FORWARDING_PORTS = [
    {"external": , "internal": , "protocol": "TCP", "description": "HTTPS-Server"},
    {"external": , "internal": , "protocol": "TCP", "description": "HTTPS-Alt"},
    {"external": , "internal": , "protocol": "TCP", "description": "HTTP"},
    {"external": , "internal": , "protocol": "UDP", "description": "Wireguard VPN"},
]

CHECK_INTERVAL = 5

# OPNsense API
OPNSENSE_API_KEY = ""
OPNSENSE_API_SECRET = "+AIF"


# ----------------------------------------------------------------------
# LOGGING
# ----------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


# ----------------------------------------------------------------------
# Fritzbox TR-064 Client
# ----------------------------------------------------------------------
class FritzboxTR064:

    def __init__(self, ip, username, password):
        self.ip = ip
        self.port = 49000
        self.auth = HTTPDigestAuth(username, password)

    def _soap(self, action, args=None):
        if args is None:
            args = {}

        body = f"""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:{action} xmlns:u="{FRITZ_WAN_SERVICE_TYPE}">
"""

        for k, v in args.items():
            body += f"<{k}>{v}</{k}>\n"

        body += f"""
    </u:{action}>
  </s:Body>
</s:Envelope>
"""

        headers = {
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPAction": f"{FRITZ_WAN_SERVICE_TYPE}#{action}"
        }

        url = f"http://{self.ip}:{self.port}{FRITZ_WAN_SERVICE_PATH}"

        r = requests.post(url, headers=headers, data=body, auth=self.auth, timeout=10)

        # Fehler auslesen
        if r.status_code != 200:
            try:
                root = ET.fromstring(r.text)
                err_code = root.find('.//{*}errorCode')
                err_desc = root.find('.//{*}errorDescription')
                if err_code is not None:
                    logger.error(f"SOAP Error {err_code.text}: {err_desc.text if err_desc is not None else ''}")
            except:
                pass
            return None

        return r

    # --------------------------------------------------------------
    def get_port_mappings(self):
        mappings = []
        idx = 0

        while True:
            r = self._soap("GetGenericPortMappingEntry", {
                "NewPortMappingIndex": idx
            })

            if r is None:
                break

            try:
                root = ET.fromstring(r.text)
                mapping = {}

                for elem in root.findall(".//{*}*"):
                    tag = elem.tag.split("}")[-1]
                    if tag.startswith("New") and elem.text:
                        mapping[tag.replace("New", "")] = elem.text

                mapping["Index"] = idx
                mappings.append(mapping)
                idx += 1

            except:
                break

        logger.info(f"Gefunden: {len(mappings)} Port-Mappings")
        return mappings

    # --------------------------------------------------------------
    def delete_mapping(self, port, proto):
        r = self._soap("DeletePortMapping", {
            "NewRemoteHost": "",
            "NewExternalPort": port,
            "NewProtocol": proto
        })
        if r:
            logger.info(f"✓ gelöscht {port}/{proto}")
            return True
        else:
            logger.warning(f"✗ löschen fehlgeschlagen {port}/{proto}")
            return False

    # --------------------------------------------------------------
    def add_mapping(self, port, wan_ip, internal, proto, desc):
        r = self._soap("AddPortMapping", {
            "NewRemoteHost": "",
            "NewExternalPort": port,
            "NewProtocol": proto,
            "NewInternalPort": internal,
            "NewInternalClient": wan_ip,
            "NewEnabled": 1,
            "NewPortMappingDescription": desc,
            "NewLeaseDuration": 0
        })
        if r:
            logger.info(f"✓ erstellt {port} → {wan_ip}:{internal} ({proto})")
            return True
        else:
            logger.error(f"✗ erstellen fehlgeschlagen {port}/{proto}")
            return False

    # --------------------------------------------------------------
    def update_for_master(self, master):
        logger.info(f"=== Update für {master['hostname']} ===")

        current = self.get_port_mappings()

        # 1. Löschen unserer Ports
        for cfg in FORWARDING_PORTS:
            for m in current:
                if str(cfg["external"]) == m.get("ExternalPort") and cfg["protocol"] == m.get("Protocol"):
                    self.delete_mapping(cfg["external"], cfg["protocol"])
                    time.sleep(0.3)

        # 2. Neu erstellen – aber nur die Ports, die auf den Master gehören
        ok = 0

        for cfg in FORWARDING_PORTS:
            if cfg["external"] in master["ports"]:
                if self.add_mapping(
                    port=cfg["external"],
                    wan_ip=master["wan_ip"],  # <-- FIXED: korrekte WAN-IP
                    internal=cfg["internal"],
                    proto=cfg["protocol"],
                    desc=f"{cfg['description']} ({master['hostname']})"
                ):
                    ok += 1
                time.sleep(0.3)

        logger.info(f"=== fertig: {ok} Regeln erstellt ===")
        return ok > 0


# ----------------------------------------------------------------------
# MASTER ERMITTLUNG
# ----------------------------------------------------------------------
def check_opnsense_master():
    for lan_ip, cfg in OPNSENSE_NODES.items():
        try:
            url = f"http://{lan_ip}/api/diagnostics/interface/getInterfaceConfig"
            r = requests.get(url, auth=(OPNSENSE_API_KEY, OPNSENSE_API_SECRET), timeout=2, verify=False)

            if r.status_code == 200:
                data = r.json()
                for iface in data.values():
                    check = str(iface).lower()
                    if "carp" in check and "master" in check:
                        logger.info(f"✓ {cfg['hostname']} ist MASTER")
                        return cfg

        except:
            # fallback: ping
            p = subprocess.run(["ping", "-c", "1", "-W", "1", lan_ip], capture_output=True)
            if p.returncode == 0:
                logger.info(f"✓ {cfg['hostname']} antwortet (Ping) → Fallback MASTER")
                return cfg

    return None


# ----------------------------------------------------------------------
# MAIN LOOP
# ----------------------------------------------------------------------
def main():
    logger.info("==========================================================")
    logger.info(" OPNsense HA Failover → Fritzbox (FIXED Version)")
    logger.info("==========================================================")

    fb = FritzboxTR064(FRITZBOX_IP, FRITZBOX_USER, FRITZBOX_PASSWORD)

    logger.info("Teste TR-064 Verbindung...")
    fb.get_port_mappings()
    logger.info("✓ Verbindung steht.\n")

    current = None

    while True:
        try:
            master = check_opnsense_master()

            if master and master != current:
                prev = current['hostname'] if current else "Keiner"
                logger.info(f"🔄 FAILOVER: {prev} → {master['hostname']}")
                if fb.update_for_master(master):
                    current = master
                    logger.info(f"✓ Failover abgeschlossen\n")
                else:
                    logger.error("❌ Failover fehlgeschlagen\n")

            time.sleep(CHECK_INTERVAL)

        except KeyboardInterrupt:
            logger.info("Bye")
            break

        except Exception as e:
            logger.error(f"Fehler: {e}")
            time.sleep(2)


if __name__ == "__main__":
    main()
