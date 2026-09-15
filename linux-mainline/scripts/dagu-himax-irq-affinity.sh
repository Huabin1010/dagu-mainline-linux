#!/bin/sh
# Pin Himax spi-gpio IRQ to Gold (CPU4-7). SoftISP on silver must not
# share the bitbang CPU with mutter. Reboot drops smp_affinity; this
# oneshot writes it back. Do not hard-code IRQ 193. Himax probe is
# delayed (IRQ enabled 2 s after spi probe) so wait for the line.
set -eu

AFFINITY="${DAGU_HIMAX_IRQ_AFFINITY:-f0}"

find_irq() {
	irq=""
	while read -r line; do
		case "$line" in
		*himax-dagu*|*himax*)
			irq=${line%%:*}
			irq=${irq#"${irq%%[![:space:]]*}"}
			break
			;;
		esac
	done </proc/interrupts
	[ -n "$irq" ] && [ -d "/proc/irq/$irq" ]
}

i=0
while ! find_irq; do
	i=$((i + 1))
	[ "$i" -gt 40 ] && {
		echo "dagu-himax-irq-affinity: no himax IRQ in /proc/interrupts" >&2
		exit 1
	}
	sleep 0.5
done

echo "$AFFINITY" >"/proc/irq/$irq/smp_affinity"
printf 'dagu-himax-irq-affinity: irq %s smp_affinity=%s list=%s effective=%s\n' \
	"$irq" \
	"$(cat "/proc/irq/$irq/smp_affinity")" \
	"$(cat "/proc/irq/$irq/smp_affinity_list")" \
	"$(cat "/proc/irq/$irq/effective_affinity_list" 2>/dev/null || echo '?')"
