// SPDX-License-Identifier: GPL-2.0-or-later
// One-off generator for the public demo confCons.xml. Run via:
//     swift run seeddemo > /path/to/demo-config.xml

import Foundation
import MRNGCore

let PW = MRNGCrypto.defaultPassword  // "mR3m"
let ITER = 1000

func enc(_ s: String) -> String {
    s.isEmpty ? "" : MRNGCrypto.encrypt(plaintext: s, password: PW, iterations: ITER)
}

func conn(name: String, host: String, proto: String, port: String,
          user: String = "", pass: String = "", domain: String = "",
          icon: String = "mRemoteNG", panel: String = "General",
          descr: String = "") -> MRNGNode {
    let n = MRNGNode.makeConnection(name: name, protocolType: proto, hostname: host)
    n.attributes["Port"] = port
    n.attributes["Icon"] = icon
    n.attributes["InheritIcon"] = "false"
    n.attributes["Panel"] = panel
    n.attributes["InheritPanel"] = "false"
    n.attributes["Descr"] = descr
    n.attributes["InheritDescription"] = "false"
    n.attributes["Username"] = user
    n.attributes["InheritUsername"] = "false"
    n.attributes["Domain"] = domain
    n.attributes["InheritDomain"] = "false"
    n.attributes["Password"] = enc(pass)
    n.attributes["InheritPassword"] = "false"
    return n
}

func folder(_ name: String) -> MRNGNode { MRNGNode.makeContainer(name: name) }

// ============================================================
// TREE
// ============================================================
let lab = folder("Lab")
lab.addChild(conn(name: "Edge Router",       host: "192.0.2.1",    proto: "SSH2", port: "22",   user: "admin",     pass: "demo-router-pass",
                   icon: "Router",   panel: "Lab", descr: "Office edge router (EdgeOS)"))
lab.addChild(conn(name: "Core Switch",       host: "192.0.2.2",    proto: "SSH2", port: "22",   user: "admin",     pass: "demo-switch-pass",
                   icon: "Switch",   panel: "Lab", descr: "HP ProCurve 48-port"))
lab.addChild(conn(name: "Firewall",          host: "192.0.2.3",    proto: "SSH2", port: "22",   user: "root",      pass: "demo-fw-pass",
                   icon: "Firewall", panel: "Lab", descr: "pfSense gateway"))
lab.addChild(conn(name: "WiFi Controller",   host: "https://192.0.2.4:8443",  proto: "HTTPS", port: "8443",
                   user: "ubnt",     pass: "demo-wifi-pass",
                   icon: "WiFi",     panel: "Lab", descr: "UniFi Network web UI"))
lab.addChild(conn(name: "Legacy console",    host: "192.0.2.5",    proto: "Telnet", port: "23",
                   icon: "Terminal Server", panel: "Lab", descr: "Out-of-band serial console"))

let servers = folder("Servers")
servers.addChild(conn(name: "Web 01",        host: "203.0.113.10", proto: "SSH2", port: "22",   user: "deploy",    pass: "demo-web01-pass",
                       icon: "Web Server", panel: "Production", descr: "nginx + PHP-FPM, public web"))
servers.addChild(conn(name: "DB 01",         host: "203.0.113.11", proto: "SSH2", port: "22022", user: "postgres", pass: "demo-db01-pass",
                       icon: "Database",   panel: "Production", descr: "PostgreSQL 16 primary"))
servers.addChild(conn(name: "Backup NAS",    host: "203.0.113.12", proto: "SSH2", port: "22",   user: "backup",    pass: "demo-nas-pass",
                       icon: "Backup",     panel: "Production", descr: "TrueNAS Scale (off-site sync)"))
servers.addChild(conn(name: "ESXi host",     host: "https://203.0.113.20", proto: "HTTPS", port: "443",
                       user: "root",       pass: "demo-esxi-pass",
                       icon: "ESX",        panel: "Production", descr: "ESXi 8 — web client"))

let workstations = folder("Workstations")
workstations.addChild(conn(name: "Office PC",  host: "10.10.20.50",  proto: "RDP",  port: "3389",
                            user: "user",     pass: "demo-rdp-pass",  domain: "OFFICE",
                            icon: "Workstation", panel: "Personal", descr: "Daily-driver Windows 11"))
workstations.addChild(conn(name: "Build Win",  host: "10.10.20.51",  proto: "RDP",  port: "3389",
                            user: "Administrator", pass: "demo-build-pass",
                            icon: "Build Server", panel: "Personal", descr: "Visual Studio build agent"))
workstations.addChild(conn(name: "Linux dev",  host: "10.10.20.52",  proto: "SSH2", port: "22",   user: "razvan",    pass: "demo-linux-pass",
                            icon: "Linux",    panel: "Personal", descr: "Debian dev box"))

let cloud = folder("Cloud")
cloud.addChild(conn(name: "AWS bastion",  host: "ec2-198-51-100-1.compute-1.amazonaws.example",
                     proto: "SSH2", port: "22", user: "ec2-user", pass: "",
                     icon: "Linux",  panel: "Cloud", descr: "SSH key auth, jump host"))
cloud.addChild(conn(name: "DigitalOcean", host: "198.51.100.42",
                     proto: "SSH2", port: "22", user: "root",     pass: "demo-do-pass",
                     icon: "Linux",  panel: "Cloud", descr: "Hobby droplet"))

// Top-level loose connections (no folder)
let pi = conn(name: "Raspberry Pi", host: "10.10.50.5", proto: "SSH2", port: "22",
              user: "pi", pass: "demo-pi-pass",
              icon: "Linux", panel: "Personal", descr: "Pi 4 — home automation")

// ============================================================
// DOCUMENT
// ============================================================
let protectedToken = MRNGCrypto.encrypt(plaintext: "ThisIsNotProtected",
                                         password: PW, iterations: ITER)
let doc = ConfCons(
    encryptionEngine: "AES",
    blockCipherMode: "GCM",
    kdfIterations: ITER,
    fullFileEncryption: false,
    protected: protectedToken,
    confVersion: "2.6",
    roots: [lab, servers, workstations, cloud, pi]
)
print(ConfConsSerializer.serialize(doc))
