# Log in to the Run:ai UI

`runai.yml` prints the URL at the end. It is always
`https://runai.<address-with-dashes>.nip.io`, where the address is the host
IP on the k3d track and the control-plane VM (`cp_vm_ip`) on the VM track.

## User and password

| | |
|---|---|
| Email | `admin@runai.local` (`runai_admin_username` in `ansible/group_vars/all.yml`) |
| Password | `$RUNAI_ADMIN_PASSWORD` if it was set during `runai.yml`, otherwise the file `~/.config/runai-oss/admin-password` on the machine that ran Ansible |

The first `runai.yml` run generates the password and writes it to that file
(mode 0600, outside the repo). Later runs, the labs (`labs/lib.sh`) and both
tracks read the same file, so the k3d and VM control planes share one
password. Show it with:

```bash
cat ~/.config/runai-oss/admin-password
```

If you change the password in the UI (user menu, top right), write the new one
into the file too. Otherwise `runai.yml`'s login check and every lab fail at
the API login.

The cluster is already registered over the REST API, so no cluster wizard
appears after the first login. The cluster shows up as `runai` (`runai_cluster_name`).

## Trust the lab CA (removes "Not Secure")

The certificates come from a self-signed CA that `runai.yml` creates in
cert-manager. It saves a copy at `~/.config/runai-oss/runai-ca.pem`. Copy that
file to the computer you browse from, and trust it there:

```bash
scp <ansible-host>:~/.config/runai-oss/runai-ca.pem .
```

**macOS** (Chrome, Safari, Edge read the system keychain):

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain runai-ca.pem
```

Or by hand: Keychain Access → System → File → Import Items → `runai-ca.pem`,
open it, Trust → "When using this certificate: Always Trust".

**Ubuntu / Debian:**

```bash
sudo cp runai-ca.pem /usr/local/share/ca-certificates/runai-oss-ca.crt
sudo update-ca-certificates
```

**Rocky / RHEL / Fedora:**

```bash
sudo cp runai-ca.pem /etc/pki/ca-trust/source/anchors/runai-oss-ca.pem
sudo update-ca-trust
```

**Windows** (PowerShell as administrator):

```powershell
Import-Certificate -FilePath runai-ca.pem -CertStoreLocation Cert:\LocalMachine\Root
```

**Firefox** keeps its own store: Settings → Privacy & Security → Certificates
→ View Certificates → Authorities → Import → tick "Trust this CA to identify
websites".

Restart the browser afterwards. Each teardown and reinstall makes a new CA, so
trust the new file again and remove the old "runai-oss" CA.

## The CLI and scripts

Nothing has to be trusted system-wide on the Ansible host: the labs call the
API with `curl -k`. For your own calls, pass the CA instead:
`curl --cacert ~/.config/runai-oss/runai-ca.pem https://runai.<...>.nip.io/api/v1/...`.
