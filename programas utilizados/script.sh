export LC_ALL=C          # garante ponto decimal (a locale pt_BR usa vírgula)
set -u

LAB="${1:?Uso: $0 <lab> <nome_maquina>}"
MAQUINA="${2:?Uso: $0 <lab> <nome_maquina>}"

# ---------------------------------------------------------------- parâmetros
IDLE_MIN="${IDLE_MIN:-0}"                      # sem sessão ociosa
# Plano de testes, na ordem de execução, no formato carga:minutos
#   cargas válidas: cpu50 cpu75 cpu100 cpu_ram mprime
PLANO="${PLANO:-cpu50:10 cpu75:10 cpu100:10 cpu_ram:10 mprime:10}"   # 10 min por etapa
SEG_POR_MIN="${SEG_POR_MIN:-60}"               # só mude para testar o script
INTERVALO="${INTERVALO:-5}"                    # segundos entre amostras
COOLDOWN="${COOLDOWN:-60}"                      # resfriamento mínimo entre etapas (s)
COOLDOWN_MAX="${COOLDOWN_MAX:-900}"            # espera máxima até a temperatura voltar ao normal (s)
TOLERANCIA_C="${TOLERANCIA_C:-3}"              # °C acima da temperatura ociosa aceitos para seguir
TOP_CADA="${TOP_CADA:-60}"                     # snapshot do top a cada N segundos
VM_BYTES="${VM_BYTES:-80%}"                    # memória usada no teste CPU+RAM
FATOR_EMISSAO="${FATOR_EMISSAO:-}"             # kgCO2e/kWh da rede elétrica (opcional)
NUCLEOS=$(nproc)

# ---------------------------------------------------------------- executáveis
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRESSNG_BIN="$SCRIPT_DIR/stress-ng/stress-ng"
MPRIME_DIR="$SCRIPT_DIR/mprime"
MPRIME_BIN="$MPRIME_DIR/mprime"
[ -x "$STRESSNG_BIN" ] || STRESSNG_BIN="$(command -v stress-ng || true)"

CARGAS=""
for item in $PLANO; do
    c="${item%%:*}"; m="${item##*:}"
    case "$c" in
        cpu50|cpu75|cpu100|cpu_ram|mprime) ;;
        *) echo "ERRO: carga desconhecida '$c' em PLANO (válidas: cpu50 cpu75 cpu100 cpu_ram mprime)"; exit 1 ;;
    esac
    if ! [[ "$item" == *:* && "$m" =~ ^[0-9]+$ && "$m" -gt 0 ]]; then
        echo "ERRO: item '$item' em PLANO deve ter o formato carga:minutos (ex.: cpu50:10)"; exit 1
    fi
    [[ " $CARGAS " == *" $c "* ]] || CARGAS+="$c "
done
CARGAS="${CARGAS% }"
if [ "$CARGAS" != "mprime" ] && [ ! -x "${STRESSNG_BIN:-}" ]; then
    echo "ERRO: stress-ng não encontrado em $SCRIPT_DIR/stress-ng/ nem no PATH"; exit 1
fi
if [[ " $CARGAS " == *" mprime "* ]] && [ ! -x "$MPRIME_BIN" ]; then
    echo "ERRO: mprime não encontrado ou sem permissão em: $MPRIME_BIN"; exit 1
fi

# ---------------------------------------------------------------- arquivos de saída
LOGDIR="$SCRIPT_DIR/logs_${LAB}_${MAQUINA}_$(date +%Y%m%d_%H%M)"
mkdir -p "$LOGDIR"
AMOSTRAS="$LOGDIR/amostras.tsv"      # série temporal contínua dos sensores
MEDICOES="$LOGDIR/medicoes.tsv"      # valores anotados do wattímetro
RESUMO="$LOGDIR/resumo.tsv"          # estatísticas por etapa (gerado ao final)
TOPLOG="$LOGDIR/top.log"
ETAPA_FILE="$LOGDIR/.etapa"
TMAX_FILE="$LOGDIR/.tmax"
ROT_PAUSA="Pausa (wattímetro)"
ROT_RESF="Resfriamento"
echo "$ROT_PAUSA" > "$ETAPA_FILE"

# ---------------------------------------------------------------- descoberta de sensores
# Só são coletadas as temperaturas da CPU (pacote e núcleos): elas validam a carga aplicada e
# revelam throttling, que altera o consumo medido. Chipset, Wi-Fi, SSD, ventoinhas, bateria e
# zonas térmicas virtuais ficam de fora por não contribuírem para o cálculo da pegada de carbono.
TEMP_FILES=(); TEMP_NOMES=()

nome_cpu() {   # $1=chip/tipo  $2=rótulo  -> NOME_SENSOR
    case "$1" in
        coretemp)
            case "$2" in
                Package*) NOME_SENSOR="CPU - Pacote ${2##* }" ;;
                Core*)    NOME_SENSOR="CPU - Núcleo ${2##* }" ;;
                *)        NOME_SENSOR="CPU - $2" ;;
            esac ;;
        k10temp|zenpower)
            case "$2" in
                Tctl)  NOME_SENSOR="CPU - Tctl (AMD)" ;;
                Tdie)  NOME_SENSOR="CPU - Tdie (AMD)" ;;
                Tccd*) NOME_SENSOR="CPU - CCD ${2#Tccd}" ;;
                *)     NOME_SENSOR="CPU - $2" ;;
            esac ;;
        *) NOME_SENSOR="CPU - Pacote" ;;
    esac
}

# 1) hwmon (coretemp / k10temp / zenpower): pacote e núcleos
for h in /sys/class/hwmon/hwmon*; do
    [ -d "$h" ] || continue
    chip="$(cat "$h/name" 2>/dev/null)"
    case "$chip" in coretemp|k10temp|zenpower) ;; *) continue ;; esac
    for t in "$h"/temp*_input; do
        [ -r "$t" ] || continue
        base="${t%_input}"
        lab="$(cat "${base}_label" 2>/dev/null || basename "$base")"
        nome_cpu "$chip" "$lab"
        TEMP_FILES+=("$t"); TEMP_NOMES+=("$NOME_SENSOR")
    done
done

# 2) alternativa: thermal_zone da CPU, usada só se o hwmon não tiver sensor de CPU
if [ "${#TEMP_FILES[@]}" -eq 0 ]; then
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/temp" ] || continue
        case "$(cat "$z/type" 2>/dev/null)" in
            x86_pkg_temp|cpu_thermal|cpu-thermal) TEMP_FILES+=("$z/temp"); TEMP_NOMES+=("CPU - Pacote") ;;
        esac
    done
fi

COLS_TEMP=(); for n in "${TEMP_NOMES[@]}"; do COLS_TEMP+=("$n (°C)"); done

# cabeçalho do arquivo de amostras
CAB="Data/hora\tEpoch (s)\tEtapa\tCarga média 1 min\tCarga média 5 min\tCarga média 15 min\tUso de CPU (%)\tFrequência média (MHz)\tMemória em uso (%)\tTemp. CPU máx. (°C)"
for c in "${COLS_TEMP[@]}"; do CAB+="\t$c"; done
printf '%b\n' "$CAB" > "$AMOSTRAS"

printf '%b\n' "Etapa\tMáquina\tLaboratório\tData\tInício (epoch)\tFim (epoch)\tDuração (s)\tConsumo (kWh)\tPotência mínima (W)\tPotência máxima (W)\tPotência atual (W)\tTensão (V)\tCorrente (A)\tTemp. CPU máx. na sessão (°C)\tCO2e (g)" > "$MEDICOES"

# ---------------------------------------------------------------- metadados do sistema
{
    echo "Data           : $(date)"
    echo "Lab / Máquina  : $LAB / $MAQUINA"
    echo "Núcleos (nproc): $NUCLEOS"
    echo "Kernel         : $(uname -a)"
    grep PRETTY_NAME /etc/os-release 2>/dev/null
    echo "Governor       : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)"
    echo "no_turbo       : $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo NA)"
    echo "Fonte de energia (online): $(cat /sys/class/power_supply/*/online 2>/dev/null | tr '\n' ' ')"
    echo "stress-ng      : $("$STRESSNG_BIN" --version 2>&1 | head -n1)"
    echo "Sensores de temperatura da CPU: ${#TEMP_FILES[@]}"
    echo "Parâmetros: IDLE_MIN=$IDLE_MIN PLANO='$PLANO' INTERVALO=$INTERVALO COOLDOWN=$COOLDOWN VM_BYTES=$VM_BYTES FATOR_EMISSAO=${FATOR_EMISSAO:-NA}"
    echo; echo "===== lscpu ====="; lscpu
    echo; echo "===== free -h ====="; free -h
    command -v sensors >/dev/null && { echo; echo "===== sensors ====="; sensors; }
} > "$LOGDIR/sistema.txt" 2>&1

cat > "$LOGDIR/LEIAME.txt" <<EOF
COMO LER ESTA PASTA DE RESULTADOS

Esta pasta foi criada pelo script de testes durante uma bateria de medições de consumo de
energia de uma máquina. Cada "sessão" (ou "etapa") é um teste de duração fixa, por exemplo
"stress-ng CPU 50% - 10 min", ou uma sessão ociosa (máquina parada, sem carga).

ARQUIVOS
* amostras.tsv: tabela com os dados coletados pelo script durante toda a execução, uma linha
  a cada ${INTERVALO} s: carga do sistema, uso de CPU, frequência, memória e temperaturas da CPU.
  Inclui as pausas e os resfriamentos, identificados na coluna "Etapa".
* resumo.tsv: tabela com os valores médios e os picos mais relevantes de amostras.tsv, uma
  linha por sessão (sem pausas nem resfriamentos). É gerada ao final da bateria, ou quando
  ela é interrompida.
* medicoes.tsv: tabela com os valores lidos no wattímetro ao fim de cada sessão (digitados
  durante a execução: consumo em kWh, potências mínima, máxima e atual, tensão e corrente),
  mais a temperatura máxima da CPU durante a sessão (calculada pelo script a partir de
  amostras.tsv). Consumo (kWh) e corrente (A) são gravados com um apóstrofo na frente
  (ex.: '0.002). A coluna CO2e só é calculada se o fator de emissão (FATOR_EMISSAO) tiver
  sido informado ao rodar o script; caso contrário aparece NA e deve ser preenchida depois
  (kWh x fator de emissão da rede elétrica).
* sistema.txt: especificações da máquina (processador, memória, sistema operacional, modo de
  frequência da CPU, se estava na tomada) e parâmetros usados na bateria. Útil para a
  planilha com os dados de cada máquina.
* <teste>_<N>min.log (ex.: cpu50_10min.log): log de cada sessão, com a saída do programa de
  teste (stress-ng ou mprime).
* top.log: registro do comando top, uma "foto" a cada ${TOP_CADA} s, com a carga do sistema (load) e
  os processos que mais usavam CPU e memória. Serve para conferir que nada além do teste
  estava consumindo recursos.
* etapas_puladas.txt: só existe se alguma sessão foi pulada; registra quais foram e quando.

FORMATO DOS ARQUIVOS .tsv
* Colunas separadas por TAB (ao abrir no Excel ou LibreOffice, escolha "Tab" como separador).
* Ponto como separador decimal. As unidades aparecem no nome da coluna: °C, W, kWh, MHz, %.
* Para cruzar medicoes.tsv com amostras.tsv, use as colunas "Início (epoch)" e "Fim (epoch)"
  de medicoes.tsv e a coluna "Epoch (s)" de amostras.tsv (tempo em segundos desde 1970).
EOF

# ---------------------------------------------------------------- amostrador (roda em segundo plano)
# $1 = valor em milésimos (ex.: milígraus) -> STR "X.Y"
milli_para_str() {
    local v=$1 s=""
    if [ "$v" -lt 0 ]; then s="-"; v=$(( -v )); fi
    printf -v STR '%s%d.%d' "$s" $(( v / 1000 )) $(( (v % 1000) / 100 ))
}

amostrar_loop() {
    local u n s i w irq sirq st tot idl ptot pidl dt di
    local etapa ts epoch ult_top=0 k f v soma nf key val mt=0 ma=0
    local l1 l5 l15 CPU FREQ MEM tmax TCPU
    local linha temp_s

    read -r _ u n s i w irq sirq st _ < /proc/stat
    ptot=$(( u + n + s + i + w + irq + sirq + st )); pidl=$(( i + w ))

    while true; do
        printf -v epoch '%(%s)T' -1
        printf -v ts '%(%d/%m/%Y %H:%M:%S)T' -1
        read -r etapa < "$ETAPA_FILE"; [ -n "$etapa" ] || etapa="$ROT_PAUSA"
        read -r l1 l5 l15 _ < /proc/loadavg

        # uso de CPU (%) desde a amostra anterior
        read -r _ u n s i w irq sirq st _ < /proc/stat
        tot=$(( u + n + s + i + w + irq + sirq + st )); idl=$(( i + w ))
        dt=$(( tot - ptot )); di=$(( idl - pidl ))
        if [ "$dt" -gt 0 ]; then
            v=$(( 1000 * (dt - di) / dt )); printf -v CPU '%d.%d' $(( v / 10 )) $(( v % 10 ))
        else CPU="NA"; fi
        ptot=$tot; pidl=$idl

        # frequência média (MHz)
        soma=0; nf=0
        for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
            [ -r "$f" ] || continue
            read -r v < "$f"; soma=$(( soma + v )); nf=$(( nf + 1 ))
        done
        if [ "$nf" -gt 0 ]; then FREQ=$(( soma / nf / 1000 )); else FREQ="NA"; fi

        # memória usada (%)
        while read -r key val _; do
            case "$key" in MemTotal:) mt=$val ;; MemAvailable:) ma=$val ;; esac
        done < /proc/meminfo
        if [ "$mt" -gt 0 ]; then
            v=$(( 1000 * (mt - ma) / mt )); printf -v MEM '%d.%d' $(( v / 10 )) $(( v % 10 ))
        else MEM="NA"; fi

        # temperaturas da CPU
        temp_s=""; tmax=-999999
        for k in "${!TEMP_FILES[@]}"; do
            v=""; { read -r v < "${TEMP_FILES[$k]}"; } 2>/dev/null
            if [[ $v =~ ^-?[0-9]+$ ]]; then
                [ "$v" -gt "$tmax" ] && tmax=$v
                milli_para_str "$v"; temp_s+="\t$STR"
            else temp_s+="\tNA"; fi
        done
        if [ "$tmax" -gt -999999 ]; then
            milli_para_str "$tmax"; TCPU=$STR; echo "$tmax" > "$TMAX_FILE"
        else TCPU="NA"; echo "NA" > "$TMAX_FILE"; fi

        linha="$ts\t$epoch\t$etapa\t$l1\t$l5\t$l15\t$CPU\t$FREQ\t$MEM\t$TCPU${temp_s}"
        printf '%b\n' "$linha" >> "$AMOSTRAS"

        # snapshot do top (usa a 2ª iteração: a 1ª mostra médias desde o boot)
        if [ $(( epoch - ult_top )) -ge "$TOP_CADA" ]; then
            ult_top=$epoch
            { echo "=== $ts | Etapa: $etapa ==="
              top -b -n 2 -d 1 | awk '/^top -/{n++} n==2' | head -n 15
              echo; } >> "$TOPLOG"
        fi
        sleep "$INTERVALO"
    done
}

# ---------------------------------------------------------------- resumo por etapa
resumir() {
    [ -s "$AMOSTRAS" ] || return 0
    awk -v pausa="$ROT_PAUSA" -v resf="$ROT_RESF" 'BEGIN{FS=OFS="\t"}
    NR==1{ next }
    {
        e=$3; if(e==resf || e==pausa) next
        if(!(e in n)){ ordem[++ne]=e; ini[e]=$2 }
        fim[e]=$2; n[e]++
        load[e]+=$4; cpu[e]+=$7; freq[e]+=$8; mem[e]+=$9; tm[e]+=$10
        if(!(e in pico) || $10>pico[e]) pico[e]=$10
    }
    END{
        printf "Etapa\tAmostras\tDuração (s)\tUso de CPU médio (%%)\tCarga média 1 min (média)\tFrequência média (MHz)\tMemória em uso média (%%)\tTemp. CPU média (°C)\tTemp. CPU pico (°C)"
        printf "\n"
        for(j=1;j<=ne;j++){
            e=ordem[j]; dur=fim[e]-ini[e]
            printf "%s\t%d\t%d\t%.1f\t%.2f\t%.0f\t%.1f\t%.1f\t%.1f", e, n[e], dur, cpu[e]/n[e], load[e]/n[e], freq[e]/n[e], mem[e]/n[e], tm[e]/n[e], pico[e]
            printf "\n"
        }
    }' "$AMOSTRAS" > "$RESUMO"
}

limpar() {
    trap - EXIT INT TERM
    if [ -n "${SAMPLER_PID:-}" ]; then kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; fi
    resumir
    echo ""
    echo "Logs dos testes : $LOGDIR"
    echo "Sensores (TSV)  : $AMOSTRAS"
    echo "Resumo (TSV)    : $RESUMO"
    echo "Wattímetro (TSV): $MEDICOES"
}
trap limpar EXIT
trap 'echo; echo "Interrompido pelo usuário."; exit 130' INT TERM

# ---------------------------------------------------------------- funções das etapas
rotulo_etapa() {   # $1=carga  $2=minutos  -> ROTULO
    local r
    case "$1" in
        ocioso)  r="Ocioso" ;;
        cpu50)   r="stress-ng CPU 50%" ;;
        cpu75)   r="stress-ng CPU 75%" ;;
        cpu100)  r="stress-ng CPU 100%" ;;
        cpu_ram) r="stress-ng CPU + RAM" ;;
        mprime)  r="mprime (Torture Test)" ;;
        *)       r="$1" ;;
    esac
    ROTULO="$r - $2 min"
}

set_etapa() { echo "$1" > "$ETAPA_FILE.tmp" && mv -f "$ETAPA_FILE.tmp" "$ETAPA_FILE"; }

aguardar_reset() {   # retorna 1 se o usuário escolher pular a etapa
    local resp
    echo ""
    echo "=============================================="
    echo "Próxima etapa: $1"
    echo "Não se esqueça de resetar o wattímetro logo depois da nova etapa começar!"
    echo "Pressione ENTER para começar a nova etapa  |  digite P e ENTER para PULAR esta etapa"
    read -r resp
    case "${resp,,}" in p|pular) return 1 ;; esac
    return 0
}

anotar_medicao() {   # $1=etapa $2=inicio_epoch $3=fim_epoch
    local etapa="$1" ini="$2" fim="$3" dur=$(( $3 - $2 ))
    local kwh pmin pmax patual tensao corr tmaxs co2="NA"
    printf '\a'
    echo ""
    echo "ANOTAR VALORES DO WATTÍMETRO - $etapa  (leia o display ANTES de digitar)"
    read -rp "  Consumo de energia (kWh) : " kwh
    read -rp "  Potência mínima    (W)   : " pmin
    read -rp "  Potência máxima    (W)   : " pmax
    read -rp "  Potência atual     (W)   : " patual
    read -rp "  Tensão             (V)   : " tensao
    read -rp "  Corrente           (A)   : " corr
    kwh=${kwh//,/.}; pmin=${pmin//,/.}; pmax=${pmax//,/.}
    patual=${patual//,/.}; tensao=${tensao//,/.}; corr=${corr//,/.}

    # CO2e (g) = kWh x fator de emissão, só se FATOR_EMISSAO foi informado
    if [[ $kwh =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ -n "$FATOR_EMISSAO" ]; then
        co2=$(awk -v k="$kwh" -v f="$FATOR_EMISSAO" 'BEGIN{printf "%.3f", k*f*1000}')
    fi

    # temperatura máxima da CPU durante esta sessão (maior valor da coluna 10 de amostras.tsv)
    tmaxs=$(awk -F'\t' -v e="$etapa" 'NR>1 && $3==e && $10 ~ /^-?[0-9]+(\.[0-9]+)?$/ { if(!n++ || $10>m) m=$10 } END{ if(n) printf "%.1f", m; else print "NA" }' "$AMOSTRAS")

    # o apóstrofo antes de kWh e corrente faz a planilha tratar o valor como texto
    printf '%b\n' "${etapa}\t${MAQUINA}\t${LAB}\t$(date '+%d/%m/%Y')\t${ini}\t${fim}\t${dur}\t'${kwh}\t${pmin}\t${pmax}\t${patual}\t${tensao}\t'${corr}\t${tmaxs}\t${co2}" >> "$MEDICOES"
    echo "  Temperatura máxima da CPU na sessão: ${tmaxs} °C"
    echo "  Registrado em: $MEDICOES"
}

rodar_carga() {   # $1=carga $2=segundos $3=arquivo de log
    local carga="$1" seg="$2" log="$3"
    local comum=(--metrics-brief --times --tz --thermalstat 10 --log-file "$log")
    case "$carga" in
        cpu50)   "$STRESSNG_BIN" --cpu "$NUCLEOS" --cpu-load 50 --timeout "${seg}s" "${comum[@]}" ;;
        cpu75)   "$STRESSNG_BIN" --cpu "$NUCLEOS" --cpu-load 75 --timeout "${seg}s" "${comum[@]}" ;;
        cpu100)  "$STRESSNG_BIN" --cpu "$NUCLEOS" --timeout "${seg}s" "${comum[@]}" ;;
        cpu_ram) "$STRESSNG_BIN" --cpu "$NUCLEOS" --vm 2 --vm-bytes "$VM_BYTES" --timeout "${seg}s" "${comum[@]}" ;;
        mprime)  ( cd "$MPRIME_DIR" && timeout --foreground -k 10 "${seg}" ./mprime -t -d ) 2>&1 | tee "$log" ;;
    esac
}

executar_etapa() {   # $1=id (ex.: cpu50_10min)  $2=carga (ou "ocioso")  $3=segundos  (retorna 1 se pulada)
    local id="$1" carga="$2" seg="$3" ini fim min rot
    min="${id##*_}"; min="${min%min}"
    rotulo_etapa "$carga" "$min"; rot="$ROTULO"
    ETAPA_N=$(( ETAPA_N + 1 ))
    set_etapa "$ROT_PAUSA"
    if [[ " ${PULAR:-} " == *" $id "* ]]; then
        echo ">>> [$ETAPA_N/$ETAPA_TOTAL] $rot - PULADA (variável PULAR)"
        echo "$(date '+%d/%m/%Y %H:%M:%S') | $rot | via variável PULAR" >> "$LOGDIR/etapas_puladas.txt"
        return 1
    fi
    if ! aguardar_reset "[$ETAPA_N/$ETAPA_TOTAL] $rot"; then
        echo ">>> [$ETAPA_N/$ETAPA_TOTAL] $rot - PULADA"
        echo "$(date '+%d/%m/%Y %H:%M:%S') | $rot | pulada pelo usuário" >> "$LOGDIR/etapas_puladas.txt"
        return 1
    fi
    set_etapa "$rot"
    ini=$(date +%s)
    echo ">>> [$ETAPA_N/$ETAPA_TOTAL] $rot - início: $(date '+%d/%m/%Y %H:%M:%S')"
    if [ "$carga" = "ocioso" ]; then sleep "$seg"; else rodar_carga "$carga" "$seg" "$LOGDIR/${id}.log"; fi
    fim=$(date +%s)
    set_etapa "$ROT_PAUSA"
    echo ">>> $rot - fim: $(date '+%d/%m/%Y %H:%M:%S')"
    anotar_medicao "$rot" "$ini" "$fim"
    return 0
}

resfriar() {
    local esp="$COOLDOWN" t
    set_etapa "$ROT_RESF"
    echo ">>> Resfriando por ${COOLDOWN}s..."
    sleep "$COOLDOWN"
    if [[ ${TEMP_BASE:-} =~ ^-?[0-9]+$ ]]; then
        while [ "$esp" -lt "$COOLDOWN_MAX" ]; do
            read -r t < "$TMAX_FILE"
            [[ $t =~ ^-?[0-9]+$ ]] || break
            [ "$t" -le $(( TEMP_BASE + TOLERANCIA_C * 1000 )) ] && break
            echo "    CPU ainda a $(( t / 1000 ))°C (ocioso: $(( TEMP_BASE / 1000 ))°C), aguardando..."
            sleep 10; esp=$(( esp + 10 ))
        done
    fi
}

# ---------------------------------------------------------------- execução
TEMP_BASE=""
ETAPA_N=0
N_ATIVAS=0; TOTAL_ATIVO=0
for item in $PLANO; do N_ATIVAS=$(( N_ATIVAS + 1 )); TOTAL_ATIVO=$(( TOTAL_ATIVO + ${item##*:} )); done
ETAPA_TOTAL=$N_ATIVAS; [ "$IDLE_MIN" -gt 0 ] && ETAPA_TOTAL=$(( ETAPA_TOTAL + 1 ))

TOTAL_MIN=$(( IDLE_MIN + TOTAL_ATIVO ))
TOTAL_MIN=$(( TOTAL_MIN + N_ATIVAS * COOLDOWN / 60 ))

echo "=============================================="
echo " Bateria de testes - Lab: $LAB | Máquina: $MAQUINA | Núcleos: $NUCLEOS"
echo " Etapas: $ETAPA_TOTAL | Tempo estimado: ~$(( TOTAL_MIN / 60 ))h$(( TOTAL_MIN % 60 ))min (sem contar pausas manuais)"
echo " Sensores de temperatura da CPU: ${#TEMP_FILES[@]}"
[ "${#TEMP_FILES[@]}" -eq 0 ] && echo " AVISO: nenhum sensor de temperatura da CPU encontrado (colunas ficarão NA)"
[ -z "$FATOR_EMISSAO" ] && echo " (FATOR_EMISSAO não definido: a coluna CO2e ficará como NA)"
echo " Logs em: $LOGDIR"
echo " Dica: rode dentro de tmux/screen e desative a suspensão automática."
echo "=============================================="
echo "Pressione ENTER para iniciar a coleta de sensores..."
read -r

amostrar_loop &
SAMPLER_PID=$!

if [ "$IDLE_MIN" -gt 0 ]; then
    if executar_etapa "ocioso_${IDLE_MIN}min" ocioso $(( IDLE_MIN * SEG_POR_MIN )); then
        read -r TEMP_BASE < "$TMAX_FILE"
    else
        echo "    (sem a etapa ociosa, o resfriamento usará apenas o tempo fixo de ${COOLDOWN}s)"
    fi
fi

for item in $PLANO; do
    c="${item%%:*}"; d="${item##*:}"
    # etapa pulada não esquenta a máquina: não precisa de resfriamento depois dela
    if executar_etapa "${c}_${d}min" "$c" $(( d * SEG_POR_MIN )); then
        [ "$ETAPA_N" -lt "$ETAPA_TOTAL" ] && resfriar
    fi
done

echo ""
echo " Bateria concluída para $LAB / $MAQUINA em $(date '+%Y-%m-%d %H:%M:%S')"
# o resumo e a listagem final são feitos pela função limpar (trap EXIT)