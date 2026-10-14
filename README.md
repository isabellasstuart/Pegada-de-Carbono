# Pegada de Carbono na Computação

![Projeto em andamento](https://img.shields.io/badge/Projeto%20em%20andamento-yellow)

O projeto "Pegada de Carbono na Computação" visa calcular e analisar a pegada de carbono gerada pelo 
Departamento de Informática no campus Centro Politécnico da UFPR, com 
foco nos escopos 1 e 2 do *Greenhouse Gas Protocol* (GHG), definidos mais
adiante.

A partir dos dados coletados, pretende-se:

- Mapear os laboratórios com maior consumo energético
- Elaborar um relatório completo da análise
- Calcular o número de árvores necessárias para mitigar o impacto gerado
- Realizar o plantio de espécies no Centro Politécnico

## Metodologia

As emissões de uma organização são classificadas pelo *Greenhouse Gas Protocol* (GHG) em três escopos:

- **Escopo 1**: emissões diretas de fontes controladas pela organização
- **Escopo 2**: emissões indiretas pelo consumo de energia elétrica
- **Escopo 3**: emissões indiretas da cadeia (exemplo: impacto gerado pelos meios de transporte de funcionários)

Este projeto foca nos **escopos 1 e 2**, com ênfase no escopo 2, pela sua relevância técnica para o curso de Ciência da Computação.

A unidade de medida utilizada é o **CO₂ equivalente (CO₂-e)**, que
compara o impacto de diferentes gases de efeito estufa ao do CO₂, com
base no Potencial de Aquecimento Global (GWP).

## Ferramentas utilizadas

- **`stress-ng`**: aplica cargas exatas de CPU (50%, 75%, 100%) e memória
- **`mprime`** (PRIME95): maximiza a carga da FPU, aproximando o consumo do TDP
- **`sensors` / `hwmon`**: leitura das temperaturas da CPU
- **Wattímetro**: medição do consumo elétrico

## Sobre este repositório

Este repositório contém as **ferramentas de estresse de máquina** utilizadas, 
o **script** e os **dados coletados** até o momento. 
O estágio atual do projeto consiste na medição do consumo de energia dos 
computadores do **Laboratório 12**, com o uso de wattímetros.

## Sobre o script

`script.sh` automatiza uma série de testes em uma máquina,
medindo o consumo de energia em diferentes cenários de carga:

- **Ocioso**: máquina parada, sem carga (duração configurável)
- **cpu50**: stress-ng com 50% de uso de CPU (10 min)
- **cpu75**: stress-ng com 75% de uso de CPU (10 min)
- **cpu100**: stress-ng com 100% de uso de CPU (10 min)
- **cpu_ram**: stress-ng com CPU + memória (10 min)
- **mprime**: MPrime (Torture Test, FPU no limite) (10 min)

Durante cada etapa, o script coleta amostras a cada 5 segundos:

- Carga do sistema (load average 1, 5 e 15 min)
- Uso de CPU (%)
- Frequência média (MHz)
- Memória em uso (%)
- Temperaturas da CPU (pacote e núcleos)

Ao final de cada etapa, o script recebe como entrada os valores do wattímetro (consumo em kWh, potências mínima/máxima/atual, tensão e corrente) e seleciona a temperatura máxima da CPU na sessão, presente em `amostras.tsv`.

## Como executar os testes

### Pré-requisitos

- Linux (testado em Ubuntu e Mint)
- `stress-ng` e `mprime` instalados em diretórios de mesmo nome, no mesmo diretório que `script.sh`
- Sensores de temperatura da CPU acessíveis via `/sys/class/hwmon`
- Wattímetro para medição do consumo

### Uso

    ./script.sh <lab> <nome_maquina>

Exemplo:

    ./script.sh lab12 h30

### Variáveis de ambiente (opcionais)

- **`IDLE_MIN`**: minutos da etapa ociosa (0 desativa; padrão: 0)
- **`PLANO`**: plano de testes (padrão: `cpu50:10 cpu75:10 cpu100:10 cpu_ram:10 mprime:10`)
- **`INTERVALO`**: segundos entre amostras (padrão: 5)
- **`COOLDOWN`**: resfriamento mínimo entre etapas em segundos (padrão: 60)
- **`FATOR_EMISSAO`**: kgCO2e/kWh da rede elétrica (opcional)
- **`VM_BYTES`**: memória usada no teste CPU+RAM (padrão: 80%)

Exemplo com fator de emissão:

    FATOR_EMISSAO=0.0385 ./script.sh lab12 pc01

## Saída gerada

Cada execução cria uma pasta `logs_<lab>_<maquina>_<data>/` com:

- **`amostras.tsv`**: registros contínuos dos sensores
- **`medicoes.tsv`**: valores anotados do wattímetro + CO2e calculado (no caso da definição de **FATOR_EMISSAO**)
- **`resumo.tsv`**: estatísticas por etapa (gerado ao final)
- **`sistema.txt`**: especificações da máquina e parâmetros usados
- **`LEIAME.txt`**: guia de leitura dos resultados
- **`top.log`**: snapshots do `top` durante a execução
- **`<teste>_<N>min.log`**: log de cada sessão de teste

Para mais detalhes sobre o formato dos arquivos, consulte o `LEIAME.txt`
dentro de cada pasta de logs.

## Créditos

Este projeto foi idealizado pelo tutor do PET Computação, **Luiz Carlos Pessoa Albini**, e atualmente é liderado pela aluna **Isabella dos Santos Stuart**.

## Referências

INTERGOVERNMENTAL PANEL ON CLIMATE CHANGE. **Climate Change**: the 1990
and 1992 IPCC Assessments. [S.l.]: IPCC, 1992. ISBN 0-662-19821-2.

MERSENNE RESEARCH. **GIMPS Download**. 1996. Disponível em:
https://www.mersenne.org/download/. Acesso em: 9 jun. 2026.

ORGANIZAÇÃO DAS NAÇÕES UNIDAS. **Protocolo de Kyoto**. Kyoto: ONU, 1997.

UBUNTU. **Kernel/Reference/stress-ng**. [s.d.]. Disponível em:
https://wiki.ubuntu.com/Kernel/Reference/stress-ng. Acesso em: 9 jun. 2026.

WORLD BUSINESS COUNCIL FOR SUSTAINABLE DEVELOPMENT; WORLD
RESOURCES INSTITUTE. **The Greenhouse Gas Protocol**: A Corporate Accounting
and Reporting Standard. Geneva: World Resources Institute, 2004.
