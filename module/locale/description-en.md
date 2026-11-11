# Gatehouse Fixes

Changes how troops use gatehouses and when gates close. Each change has its own switch. Requiring stairs to reach walls is optional and off by default.

## Blocked trips are remembered

With "stairs needed" on, a unit whose way is blocked has every gatehouse tried for it, one by
one - a dozen route searches across the whole map. When an army is ordered somewhere at once,
every soldier made that same hopeless trip, and the game stuttered. Now a trip that found no
way is remembered for 100 game ticks (a setting), and the soldiers behind go straight to the
game's own search.
