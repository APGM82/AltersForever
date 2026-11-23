#!/usr/bin/env python3
"""Regenera RecipeItems.lua con las tablas del cliente (wago.tools).

  python3 herramientas/actualizar_datos.py              # build instalada (.build.info)
  python3 herramientas/actualizar_datos.py 1.60.1.71037

Hacerlo tras cada parche que traiga recetas nuevas. RecipeItems.lua dice que receta ensena cada objeto de
receta (patron, formula, planos, esquema...): el hechizo con disparador 6 (aprender) del objeto, que es el
mismo id que da C_TradeSkillUI. La API del juego no lo da, y el nombre del objeto no sirve: "Recipe:
Transmute Iron to Gold" ensena "Transmute: Iron to Gold", "Patron: toga de lino rojo" ensena "Toga roja de
lino"... (un 30 % de los objetos en ingles y un 45 % en espanol con la build 71037). Los objetos que no esten
en la tabla se siguen buscando por el nombre.
"""

import collections
import csv
import io
import os
import sys
import urllib.request

AQUI = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(AQUI, "..", "AltersForever")
WOW = os.path.expanduser("~/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft")
URL = "https://wago.tools/db2/{tabla}/csv?build={build}"

RECETA = 9
LIBRO = 0           # libros de clase (grimorios, manuales): no son de profesion
APRENDER = "6"      # ItemEffect.TriggerType: ITEM_SPELLTRIGGER_LEARN_SPELL_ID


def build_instalada():
    with open(os.path.join(WOW, ".build.info"), encoding="utf-8") as f:
        filas = list(csv.reader(f, delimiter="|"))
    columnas = [c.split("!")[0] for c in filas[0]]
    versiones = [dict(zip(columnas, fila)).get("Version", "") for fila in filas[1:]]
    forever = [v for v in versiones if v.startswith("1.")]
    if not forever:
        sys.exit("no encuentro la build de Forever en .build.info; pasala a mano")
    return max(forever, key=lambda v: [int(x) for x in v.split(".")])


def tabla(nombre, build):
    # sin un User-Agent propio wago.tools responde 403
    peticion = urllib.request.Request(URL.format(tabla=nombre, build=build),
                                      headers={"User-Agent": "alters-forever/1.0"})
    with urllib.request.urlopen(peticion, timeout=300) as r:
        texto = r.read().decode("utf-8-sig")
    filas = list(csv.DictReader(io.StringIO(texto)))
    if not filas:
        sys.exit(f"wago.tools no tiene {nombre} para la build {build}")
    return filas


def main():
    build = sys.argv[1] if len(sys.argv) > 1 else build_instalada()
    print(f"build {build}")

    recetas = {int(f["ID"]): int(f["SubclassID"]) for f in tabla("Item", build)
               if int(f["ClassID"]) == RECETA and int(f["SubclassID"]) != LIBRO}
    efectos = {f["ID"]: f for f in tabla("ItemEffect", build)}
    de_profesion = {int(f["Spell"]) for f in tabla("SkillLineAbility", build)}

    ensena = collections.defaultdict(set)
    for f in tabla("ItemXItemEffect", build):
        objeto, efecto = int(f["ItemID"]), efectos.get(f["ItemEffectID"])
        if objeto in recetas and efecto and efecto["TriggerType"] == APRENDER:
            hechizo = int(efecto["SpellID"])
            if hechizo in de_profesion:
                ensena[objeto].add(hechizo)

    varias = sorted(o for o, h in ensena.items() if len(h) > 1)
    if varias:
        # el addon guarda una receta por objeto; si llega a pasar, hay que cambiarlo
        sys.exit(f"objetos que ensenan mas de una receta: {varias[:20]}")
    pares = sorted((o, h.pop()) for o, h in ensena.items())

    por_subclase = collections.Counter(recetas[o] for o, _ in pares)
    print("objetos por subclase:", dict(sorted(por_subclase.items())))

    lineas = ["    " + " ".join(f"[{o}] = {h}," for o, h in pares[n:n + 6]) for n in range(0, len(pares), 6)]
    archivo = os.path.join(ADDON, "RecipeItems.lua")
    with open(archivo, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- Objetos de receta (patrones, formulas, planos...) y la receta que ensena cada uno.\n")
        f.write(f"-- Generado por herramientas/actualizar_datos.py con la build {build}: no tocar a mano.\n\n")
        f.write("local _, ns = ...\n\n")
        f.write("-- objeto -> id de la receta, el mismo que da C_TradeSkillUI\n")
        f.write("ns.recipeItems = {\n")
        f.writelines(linea + "\n" for linea in lineas)
        f.write("}\n")
    print(f"RecipeItems.lua: {len(pares)} objetos")


if __name__ == "__main__":
    main()
