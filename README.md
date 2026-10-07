# Alters Forever

A light alt manager for World of Warcraft: Forever. I wanted to know what my
other characters were carrying without logging into each of them, so I wrote
this.

Every character you log in with gets remembered: level and experience, gold,
rested XP, zone, time played, and what it has in its bags, bank, mail and on
the auction house. Hover any item and the tooltip tells you who has it and
where. The bank, mail and auction house are read when you open them, so visit
each once per character.

`/alts` (or the minimap button) opens the window.

The Characters tab lists everyone with their gold and rested XP, and the
rested amount keeps going up while a character is logged out, the same way the
game does it. Click a character to open its page, which works like the
in-game character window. The icons next to the name switch between items,
talents, legacy trees, reputation, skills, PvE/PvP, currency, attributes and
the numbers from the game's statistics window. Talents and legacy trees show
the points each character has spent, and PvE/PvP starts with the instances and
world bosses it is saved to. Items are shown bag by bag, each bag under its own
divider with its name and how full it is, slot for slot as it is in the game,
empty slots included. They can be filtered by bags, bank, mail, equipped or
auction. Equipped gear is laid out like the paper doll.

Professions shows the ranks of every character side by side. Click one to see
its recipes, coloured by how likely they are to give a skill-up, with their
materials and how many of them that character has. You can search recipes by
name or by material. Recipe items in tooltips say who already knows them, who
can learn them and who still needs more skill.

Cooldowns collects profession cooldowns (transmutes, mooncloth and the like)
from all your characters and tells you in chat when one is ready.

Columns can be sorted by clicking their header. Characters you don't want to
see can be hidden with a right click, without deleting anything.

By default the window uses the game's own frames and buttons, so it looks like
any other Blizzard window. There are also seven colour themes if you prefer
something different. Size and opacity can be changed, and every colour lives
in `Themes.lua` if you want to make your own.

## Commands

| Command | What it does |
| --- | --- |
| `/alts` | Open or close the window |
| `/alts tooltip` | Turn the item tooltip lines on or off |
| `/alts button` | Show or hide the minimap button |
| `/alts theme horde` | Change the colours (`green`, `blue`, `purple`, `grey`, `classic`, `alliance`, `horde`, `blizzard`) |
| `/alts scale 1.2` | Window size, from 0.6 to 1.6 |

`/af` and `/alters` work the same as `/alts`.

## Languages

English, Spanish, German, French, Italian, Portuguese, Russian, Korean, and
Simplified and Traditional Chinese.

## Installation

Put the `AltersForever` folder in `World of Warcraft\_classic_beta_\Interface\AddOns\`
and restart the game. Made for Forever 1.60.1 (`Interface: 16001`).

## License

MIT
