#!/bin/bash
# author: yin-jianhong@163.com
# ref: https://cloudinit.readthedocs.io/en/latest/topics/examples.html

LANG=C
HostName=mylinux
Repos=()
BPKGS=
PKGS=
Intranet=no
baseUrl=https://raw.githubusercontent.com/tcler/kiss-vm-ns/master
bkrClientImprovedUrl=https://raw.githubusercontent.com/tcler/bkr-client-improved/master

is_available_url() {
        local _url=$1
        curl --connect-timeout 8 -m 16 --output /dev/null --silent --head --fail $_url &>/dev/null
}
is_intranet() {
	local iurl=http://download.devel.redhat.com
	is_available_url $iurl
}

Usage() {
	cat <<-EOF >&2
	Usage: $0 <iso file path> [--hostname name] [--repo name:url [--repo name:url]] [-b|--brewinstall "pkg list"] [-p|--pkginstall "pkg list"] [--kdump] [--fips]
	EOF
}

_at=`getopt -o hp:b:D \
	--long help \
	--long hostname: \
	--long repo: \
	--long pkginstall: \
	--long brewinstall: \
	--long sshkeyf: \
	--long kdump \
	--long fips \
    -a -n "$0" -- "$@"`
eval set -- "$_at"
while true; do
	case "$1" in
	-h|--help) Usage; shift 1; exit 0;;
	-D) Debug=yes; shift 1;;
	--hostname) HostName="$2"; shift 2;;
	--repo) Repos+=($2); shift 2;;
	-p|--pkginstall) PKGS="$2"; shift 2;;
	-b|--brewinstall) BPKGS="$2"; shift 2;;
	--sshkeyf) sshkeyf="$2"; shift 2;;
	--kdump) kdump=yes; shift 1;;
	--fips) fips=yes; shift 1;;
	--) shift; break;;
	esac
done

isof=$1
if [[ -z "$isof" ]]; then
	Usage
	exit
else
	mkdir -p $(dirname $isof)
	touch $isof
	isof=$(readlink -f $isof)
fi

is_intranet && {
	Intranet=yes
	baseUrl=http://download.devel.redhat.com/qa/rhts/lookaside/kiss-vm-ns
	bkrClientImprovedUrl=http://download.devel.redhat.com/qa/rhts/lookaside/bkr-client-improved
}

sshkeyf=${sshkeyf:-/dev/null}
tmpdir=/tmp/.cloud-init-iso-gen-$$
mkdir -p $tmpdir
pushd $tmpdir &>/dev/null

echo "local-hostname: ${HostName}" >meta-data

cat >user-data <<-EOF
#cloud-config
users:
  - default

  - name: root
    plain_text_passwd: redhat
    lock_passwd: false
    ssh_authorized_keys:
      - $(tail -n1 ${sshkeyf})

  - name: foo
    group: users, admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: redhat
    lock_passwd: false
    ssh_authorized_keys:
      - $(tail -n1 ${sshkeyf})

chpasswd: { expire: False }

yum_repos:
$(
for repo in "${Repos[@]}"; do
read name url <<<"${repo/:/ }"
[[ ${url:0:1} = / ]] && { name=; url=$repo; }
name=${name:-repo$((i++))}
cat <<REPO
  ${name}:
    name: $name
    baseurl: "$url"
    enabled: true
    gpgcheck: false
    skip_if_unavailable: true

REPO
done
)

runcmd:
  - test -f /etc/dnf/dnf.conf && { echo strict=0 >>/etc/dnf/dnf.conf; ln -s /usr/bin/{dnf,yum}; }
  - sed -ri -e '/^#?PasswordAuthentication /{s/no/yes/;s/^#//}' -e 's/^#?(PermitRootLogin) .*$/\1 yes/' /etc/ssh/sshd_config && service sshd restart
  - echo net.ipv4.conf.all.rp_filter=2 >>/etc/sysctl.conf && sysctl -p
  - which yum && yum install -y curl wget $PKGS
  -   which apt-get && apt-get install -y curl wget $PKGS
  -   which zypper && zypper install -y curl wget $PKGS
$(
[[ $Intranet = yes ]] && cat <<IntranetCMD
  - which yum && curl -L -m 30 -o /usr/bin/brewinstall.sh "$bkrClientImprovedUrl/utils/brewinstall.sh" &&
    chmod +x /usr/bin/brewinstall.sh && brewinstall.sh $BPKGS -noreboot
IntranetCMD
)
$(
[[ "$fips" = yes ]] && cat <<FIPS
  - which yum && curl -L -m 30 -o /usr/bin/enable-fips.sh "$baseUrl/utils/enable-fips.sh" &&
    chmod +x /usr/bin/enable-fips.sh && enable-fips.sh
FIPS
)
$(
[[ "$kdump" = yes ]] && cat <<KDUMP
  - which yum && curl -L -m 30 -o /usr/bin/kdump-setup.sh "$baseUrl/utils/kdump-setup.sh" &&
    chmod +x /usr/bin/kdump-setup.sh && kdump-setup.sh
KDUMP
)
$(
[[ "$kdump" = yes || "$fips" = yes || -n "$BPKGS" ]] && cat <<REBOOT
  - reboot
REBOOT
)
EOF

genisoimage -output $isof -volid cidata -joliet -rock user-data meta-data

popd &>/dev/null

[[ -n "$Debug" ]] && cat $tmpdir/*
rm -rf $tmpdir
