#!/usr/bin/env python3
"""Regenera RecipeItems.lua y Cooldowns.lua con las tablas del cliente (wago.tools).

  python3 herramientas/actualizar_datos.py              # build instalada (.build.info)
  python3 herramientas/actualizar_datos.py 1.60.1.71037

Hacerlo tras cada parche que traiga recetas nuevas. RecipeItems.lua dice que receta ensena cada objeto de
receta (patron, formula, planos, esquema...): el hechizo con disparador 6 (aprender) del objeto, que es el
mismo id que da C_TradeSkillUI. La API del juego no lo da, y el nombre del objeto no sirve: "Recipe:
Transmute Iron to Gold" ensena "Transmute: Iron to Gold", "Patron: toga de lino rojo" ensena "Toga roja de
lino"... (un 30 % de los objetos en ingles y un 45 % en espanol con la build 71037). Los objetos que no esten
en la tabla se siguen buscando por el nombre.

Cooldowns.lua dice cuanto dura la espera de cada receta que la tiene, y si la comparte con otras (las
transmutaciones: fabricar una pone todas en espera, lo que dure la fabricada). Tambien la de hechizos que no
son recetas pero se usan igual, como Estudio dedicado (talento de legado). El addon apunta la hora de
servidor al fabricar y le suma esto; no le pregunta al juego cuanto falta, porque su cronometro cuenta desde
que se encendio el PC y falla si se reinicia con una espera en marcha.
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
ESPERA_MINIMA = 3600  # segundos; por debajo (hoguera, fuego elemental: minutos) no se listan
OTROS = {
    1225469: "Estudio dedicado",  # talento de legado: +1 a la profesion mas baja, cada 23 h
}


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
    habilidades = tabla("SkillLineAbility", build)
    de_profesion = {int(f["Spell"]) for f in habilidades}

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

    esperas(build, habilidades)


def esperas(build, habilidades):
    # solo las de la ventana de profesion: tienen categoria de receta (la hoguera o el dragonizo no)
    recetas = {int(f["Spell"]) for f in habilidades if f["TradeSkillCategoryID"] != "0"} | set(OTROS)
    tiempos = {int(f["SpellID"]): f for f in tabla("SpellCooldowns", build) if f["DifficultyID"] == "0"}
    categorias = {int(f["SpellID"]): f for f in tabla("SpellCategories", build) if f["DifficultyID"] == "0"}
    info = {f["ID"]: f for f in tabla("SpellCategory", build)}

    filas = []
    for receta in sorted(recetas):
        t = tiempos.get(receta)
        if not t:
            continue
        propia, compartida = int(t["RecoveryTime"]) // 1000, int(t["CategoryRecoveryTime"]) // 1000
        categoria = categorias.get(receta, {}).get("Category", "0")
        cargas = categorias.get(receta, {}).get("ChargeCategory", "0")
        if max(propia, compartida) < ESPERA_MINIMA:
            if receta in OTROS:
                sys.exit(f"{OTROS[receta]} ({receta}) ya no tiene espera: quitalo de OTROS")
            continue
        # el addon no sabe de cargas ni de esperas que acaban con el reinicio diario: si aparecen, cambiarlo
        if cargas != "0" or info.get(categoria, {}).get("Flags", "0") != "0":
            sys.exit(f"la receta {receta} tiene cargas o una categoria con flags: el addon no lo contempla")
        if compartida and categoria != "0":
            filas.append((receta, compartida, int(categoria)))
        else:
            filas.append((receta, propia, None))
    faltan = set(OTROS) - {receta for receta, _, _ in filas}
    if faltan:
        sys.exit(f"no encuentro la espera de {sorted(faltan)}: revisar OTROS")
    # la categoria solo importa si la comparten varias (Estudio dedicado tiene una para el solo)
    cuantas = collections.Counter(categoria for _, _, categoria in filas)
    filas = [(r, t, c if c and cuantas[c] > 1 else None) for r, t, c in filas]

    archivo = os.path.join(ADDON, "Cooldowns.lua")
    with open(archivo, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- Recetas (y Estudio dedicado) con tiempo de espera: cuanto dura y, si la comparten\n")
        f.write("-- (transmutaciones), su categoria.\n")
        f.write(f"-- Generado por herramientas/actualizar_datos.py con la build {build}: no tocar a mano.\n\n")
        f.write("local _, ns = ...\n\n")
        f.write("-- hechizo -> { segundos, categoria compartida }\n")
        f.write("ns.cooldowns = {\n")
        for receta, segundos, categoria in filas:
            extra = f", {categoria}" if categoria else ""
            f.write(f"    [{receta}] = {{ {segundos}{extra} }},\n")
        f.write("}\n")
    print(f"Cooldowns.lua: {len(filas)} esperas")


if __name__ == "__main__":
    main()
