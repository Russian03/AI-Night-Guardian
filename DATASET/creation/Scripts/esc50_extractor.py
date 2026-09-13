import os
import shutil

categorias_esc50 = {
    '24': 'coughing',
    '20': 'cryingbaby',
    '21': 'sneezing',
    '28': 'snoring',
    '10': 'rain',
    '18': 'toiletflush',
    '19': 'thunderstorm',
    '23': 'breathing',
    '25': 'footsteps',
    '26': 'laughing',
    '37': 'clockalarm',
    '42': 'siren'
}

carpeta_origen = "audios_origen"
carpeta_destino = "audios_extraidos"
os.makedirs(carpeta_destino, exist_ok = True)

archivos_existentes = set(os.listdir(carpeta_destino))
archivos_copiados = 0
for archivo in os.listdir(carpeta_origen):
    if archivo.endswith(".wav"):
        partes = archivo.replace(".wav", "").split("-")
        id_categoria = partes[-1]
        if id_categoria in categorias_esc50:
            clase_proyecto = categorias_esc50[id_categoria]
            nuevo_nombre = f"{clase_proyecto}_esc50_{archivo}"

            if not nuevo_nombre in archivos_existentes: # Filtro archivos existentes
                ruta_origen = os.path.join(carpeta_origen, archivo)
                ruta_destino = os.path.join(carpeta_destino, nuevo_nombre)

                shutil.copy2(ruta_origen, ruta_destino)
                archivos_copiados += 1
print(f"Completado: Se han copiado y renombrado {archivos_copiados} nuevos audios de ESC-50.")
