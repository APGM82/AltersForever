# Changelog

## 1.35

- Recipe items now say which of your characters know them even with the item tooltip lines turned off. They have their own switch in Options, "Show which alts know each recipe", so you can leave the item counts to another addon and keep the recipe lines.
- One more recipe item from the latest patch is matched to the recipe it teaches.

## 1.34

- The rested XP of logged-out characters was far too low. When you log out the game no longer says how much rested XP you have or whether you are in an inn or city, so every character was saved with none and as if it were out in the open, where it fills four times slower. Now the addon keeps what the game said while you played. Characters saved by an older version show their rested XP in gray, as a minimum, until you log in with them once.
- Recipe items in tooltips now say who already knows them every time. The item was matched to its recipe by name, and about a third of patterns, formulas, plans and schematics are named differently from the recipe they teach ("Recipe: Transmute Iron to Gold" teaches "Transmute: Iron to Gold"; in Spanish almost half), so a character that already knew the recipe showed up under "Can learn it". Now each recipe item is matched to its recipe exactly.
- Characters whose skill is too low for a recipe item now show under "Not enough skill yet", with their skill and the one it asks for. The required skill was never read from the tooltip, so they all showed up under "Can learn it".
- Rest rate: hovering a character in the Characters tab, or its rested XP on the character page, shows how fast it fills up (15% of a level a day in an inn or city, a quarter of that elsewhere), when it will be full, and its ranks in the Well Rested legacy talent, which adds 4% per rank to both the rate and the cap. The rested XP of logged-out characters counts the talent too.
- The section icons on the character page no longer run under the Back button. The realm only shows next to the name when you have characters on more than one, and a name that still does not fit ends in "...".
- Auctions start below the Bags, Bank, Mail... buttons instead of on top of them.
- Buttons are as wide as their text, and a text that does not fit ends in "..." instead of spilling out. The profession buttons on the recipe page shrink together when they do not fit in one row.
- The "open the auction house with this character" message no longer stays over the bags after switching back to them.
- Long guild names, the recipe search hint and the line under each name stay inside the window.

## 1.33

- Legacy trees are drawn right again. A patch changed the spacing between their talents, and some ended up in the wrong row or column.
- When a patch changes a class's talents, characters of that class that have not logged in since show "Log in with this character once to read this" instead of their old points on the wrong talents.

## 1.32

- Shift-click a recipe in Professions to link it in chat, as in the profession window: the item it makes, or the recipe itself when it makes none (enchantments).

## 1.31

- No more "attempt to perform arithmetic on a secret number value" error in combat. Attributes are read when the fight ends instead.
- A wand shot, or any other cast, could put every recipe of a profession in Cooldowns. Fixed, and the recipes it put there are gone.

## 1.30

- New Forever theme, now the default: dark glass with bronze lines, buttons with relief and a gold edge under the mouse, a gold bar on the row under the mouse, and headings in the quest-title font. If you had already picked a theme you keep it; the Options tab or `/alts theme forever` switches to it.
- Guild tab: the guild bank, tab by tab and slot for slot as in the game, with its gold, a search box and the tab icons on the right to jump to each tab. It is read when you open the guild bank, from any character in the guild.
- Item tooltips and the Search tab also count what is in the guild bank.
- Characters in different guilds: one button per guild at the top of the Guild tab, or a list when there are more than three. Right click forgets a guild bank. Two guilds with the same name on different rulesets show the ruleset next to the name.

## 1.20

- Items are grouped bag by bag, each bag under a divider with its icon, name and used slots. The row of bags under the grid is gone.
- Bags are drawn slot for slot, in the same order as in the game and with their empty slots. Characters need to log in (and open the bank) once to get this.
- With the Blizzard theme the slots use the game's bag slot art.
- Clicking a bag's divider collapses or expands it, Shift-click does all of them. It is remembered between sessions.
- Gold this week counts from the game's weekly reset instead of Monday. Hovering the total shows when today and the week start.
- Translations written with their accents and umlauts (German, Spanish, French, Italian and Portuguese).

## 1.10

- Talents: each character's talent trees, with the points spent and still free.
- Legacy: the legacy trees of every character and the shared pool of legacy points.
- PvE/PvP now starts with the saved instances and world bosses, with their reset time.
- Statistics: the numbers from the game's statistics window (gold looted, auctions posted and so on). The old Stats section is now called Attributes.
- The sections of the character page are a row of icons next to the name instead of text buttons.

## 1.00

First release.
