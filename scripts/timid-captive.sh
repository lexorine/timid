# Body of the timid-captive launcher; BIN (sandboxed ephemeral browser) is
# prepended by flake.nix. Hosts' nmcli/resolvectl are looked up on PATH.
mode=auto
iface=
url=http://neverssl.com
dry=0

usage() {
  cat <<EOF
Usage: ${0##*/} [--dns auto|dhcp|gateway] [--iface IF] [--url URL] [--print] [-- BROWSER_ARGS...]

Throwaway sandboxed browser whose resolv.conf is built from the network's own
DNS, for signing in to captive portals (system resolver is often a local DoT/
VPN stub that the portal blocks).

  --dns auto      DHCP-provided DNS, else the default gateway (default)
  --dns dhcp      DHCP-provided DNS only; fail if none is found
  --dns gateway   default gateway IP only
  --iface IF      interface to use instead of the default-route one
  --url URL       page to open (default: $url)
  --print         show the resolv.conf that would be used and exit
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    --dns) mode=${2:?--dns needs a value}; shift 2 ;;
    --dns=*) mode=${1#*=}; shift ;;
    --iface) iface=${2:?--iface needs a value}; shift 2 ;;
    --iface=*) iface=${1#*=}; shift ;;
    --url) url=${2:?--url needs a value}; shift 2 ;;
    --url=*) url=${1#*=}; shift ;;
    --print) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case $mode in auto|dhcp|gateway) ;; *) echo "bad --dns: $mode" >&2; exit 2 ;; esac

if [ -z "$iface" ]; then
  iface=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi
[ -n "$iface" ] || { echo "no default-route interface; pass --iface" >&2; exit 1; }

dhcp_dns() {
  local out=
  if command -v nmcli >/dev/null 2>&1; then
    out=$(nmcli -g IP4.DNS,IP6.DNS device show "$iface" 2>/dev/null | tr '|' '\n' | tr -s ' \n' '\n')
  fi
  if [ -z "$out" ] && command -v resolvectl >/dev/null 2>&1; then
    out=$(resolvectl dns "$iface" 2>/dev/null | sed 's/^[^:]*://' | tr -s ' ' '\n')
  fi
  printf '%s\n' "$out" | grep -E '^[0-9a-fA-F:.]+$' || true
}

gateway_dns() {
  ip -4 route show default dev "$iface" | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}'
}

servers=
case $mode in
  dhcp) servers=$(dhcp_dns) ;;
  gateway) servers=$(gateway_dns) ;;
  auto)
    servers=$(dhcp_dns)
    [ -n "$servers" ] || servers=$(gateway_dns)
    ;;
esac
[ -n "$servers" ] || { echo "no DNS found on $iface (mode: $mode)" >&2; exit 1; }

conf=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/timid-captive-resolv.XXXXXX")
trap 'rm -f "$conf"' EXIT
{
  while read -r ns; do printf 'nameserver %s\n' "$ns"; done <<<"$servers"
  printf 'options timeout:2 attempts:2\n'
} >"$conf"

if [ "$dry" = 1 ]; then
  echo "# iface $iface, mode $mode" >&2
  cat "$conf"
  exit 0
fi

export TIMID_RESOLV_CONF=$conf
# No exec: the trap must remove $conf once the browser exits.
"$BIN" "$url" "$@"
