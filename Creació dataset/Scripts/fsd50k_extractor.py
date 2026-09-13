import pandas as pd
import os
import shutil

type = "dev"
# type = "eval"
categorias_mids = {
    '/m/03q5_w': 'burpingandeructation',
    '/m/01b_21': 'cough',
    '/m/0463cq4': 'cryingandsobbing',
    '/m/09hlz4': 'respiratorysounds',
    '/m/03qc9zr': 'screaming',
    '/m/07p6fty': 'shout',
    '/m/01hsr_': 'sneeze',
    '/m/07qnq_y': 'thumpandthud',
    '/m/07sr1lc': 'yell',
    '/m/07pp_mv': 'alarm',
    '/m/0lyf6': 'breathing',
    '/t/dd00134': 'carpassingby',
    '/m/07rkbfh': 'chatter',
    '/m/01h8n0': 'conversation',
    '/m/02dgv': 'door',
    '/m/09l8g': 'humanvoice',
    '/m/01j3sz': 'laughter',
    '/m/06mb1': 'rain',
    '/m/03kmc9': 'siren',
    '/m/09x0r': 'speech',
    '/m/0jb2l': 'thunderstorm',
    '/m/0btp2': 'trafficandroadwaynoise',
    '/m/0912c9': 'vehiclehornandcarhornandhonking',
    '/m/07pbtc8': 'walkandfootsteps',
    '/m/0838f': 'water'
}

archivo_csv = f'{type}.csv'
carpeta_origen = f"FSD50K.{type}_audio"
carpeta_destino = f"audios_extraidos_{type}"
os.makedirs(carpeta_destino, exist_ok = True)

archivos_existentes = set(os.listdir(carpeta_destino))
df = pd.read_csv(archivo_csv)
archivos_copiados = 0
for index, row in df.iterrows():
    fname = str(row['fname']) + '.wav'
    fila_texto = row.astype(str).str.cat(sep = ' ')

    categoria_final = None
    for mid, categoria in categorias_mids.items():
        if mid in fila_texto:
            categoria_final = categoria
            break

    if categoria_final:
        ruta_origen = os.path.join(carpeta_origen, fname)
        ruta_destino = os.path.join(carpeta_destino, f"{categoria_final}_fsd50k_{fname}")

        if os.path.exists(ruta_origen) and not f"{categoria_final}_fsd50k_{fname}" in archivos_existentes: # Filtro archivos existentes
            shutil.copy2(ruta_origen, ruta_destino)
            archivos_copiados += 1

print(f"Completado: Se han extraído y renombrado {archivos_copiados} nuevos audios de FSD50K.")
