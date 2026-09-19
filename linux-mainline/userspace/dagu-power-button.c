/*
 * Retired. logind owns KEY_POWER and gpio-keys SW_LID (GPIO110 hall).
 * Do not EVIOCGRAB the pwrkey and do not spawn a power card.
 * This binary stays so a leftover unit cannot crash-loop; it does
 * nothing. The service must stay disabled.
 */
#include <unistd.h>

int main(void)
{
	for (;;)
		pause();
}
