#!/bin/bash
# Makineye özgü yol denetimi: kaynakta, testte, belgede ya da paketlemede bir geliştirici makinesinin ev klasörü
# (/Users/<ad>/, /home/<ad>/, C:\Users\<ad>\) ya da bir oturumun geçici klasörü (claude-NNN) başka makinede kırılır.
#
#   scripts/check-paths.sh [depo-klasörü]      (varsayılan: bu betiğin deposu)
#
# Denetim izlenen dosyaların hepsini tarar (git grep). Git yoksa ya da git grep çalışamazsa denetim YAPILAMAMIŞTIR ve
# başarısız sayılır: "bir şey bulunamadı" ile "bakılamadı" aynı şey değildir. Çıkış: 0 temiz, 1 bulgu ya da denetlenemedi.
set -uo pipefail
cd "${1:-$(dirname "$0")/..}" || { echo "BAŞARISIZ: klasör açılamadı: ${1:-}"; exit 1; }

# /Users/<ad>/ · /home/<ad>/ (ad bir harf ya da rakamla başlar: /home/.claude gibi ev-altı klasörler değil) ·
# C:\Users\<ad> ve C:\\Users\\<ad> (kaynakta kaçışlı yazılır) ve C:/Users/<ad> · oturum klasörü claude-NNN
pattern='/Users/[A-Za-z0-9_.-]+/|/home/[A-Za-z0-9][A-Za-z0-9_.-]*/|[A-Za-z]:(\\\\?|/)Users(\\\\?|/)[A-Za-z0-9_.-]+|claude-[0-9]{3}'
# Belgelerde yer tutucu adlar yazılır (C:\Users\you\...): bunlar bir makine değil.
placeholder='(Users|home)(\\\\?|/)(you|siz|user|username|name|yourname|your-name|me|public|default)([\\/ `"'"'"')]|$)'

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "yol denetimi denetlenemedi: burası bir git deposu değil ($(pwd))"
  echo "BAŞARISIZ: makineye özgü yol denetimi yapılamadı (git deposu yok)"
  exit 1
fi

found=$(git grep -nIE "$pattern" -- . ':!scripts/check.sh' ':!scripts/check-paths.sh' 2>&1)
status=$?
if [ "$status" -gt 1 ]; then
  echo "$found" | head -3
  echo "BAŞARISIZ: makineye özgü yol denetimi yapılamadı (git grep hata verdi: $status)"
  exit 1
fi
if [ "$status" -eq 0 ]; then
  found=$(echo "$found" | grep -vE "$placeholder" || true)
fi
if [ -n "$found" ]; then
  echo "$found" | head -5
  echo "BAŞARISIZ: makineye özgü yol"
  exit 1
fi
echo "temiz"
