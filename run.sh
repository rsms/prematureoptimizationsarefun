#!/bin/bash
set -e
CFLAGS="$CFLAGS -std=c++11 -stdlib=libc++ -O3 -DNDEBUG"

echo clang $CFLAGS -Wall -lc++ -o program source.cc $@ '&& ... output.S'
clang $CFLAGS -Wall -lc++ -o program source.cc $@

mkdir -p archive

if (ls archive/source-*.cc) >/dev/null 2>&1; then
  PREVIOUS_SOURCE_FILE=$(ls archive/source-*.cc | sort -r | head -n1)
  PREVIOUS_TIMESTAMP=$(echo "$PREVIOUS_SOURCE_FILE" | sed -E 's:archive/source-([0-9\.\-]+)\.cc:\1:g')
fi

SOURCE_TIMESTAMP=$(stat -f '%Sm' -t '%Y-%m-%d-%H.%M.%S' source.cc)

SOURCE_ARCHIVE_FILE=archive/source-$SOURCE_TIMESTAMP.cc
if [ ! -z $PREVIOUS_TIMESTAMP ] && [ -f $PREVIOUS_SOURCE_FILE ]; then
  set +e
  if [ "$PREVIOUS_SOURCE_FILE" != "$SOURCE_ARCHIVE_FILE" ] &&
     ! (diff -q $PREVIOUS_SOURCE_FILE source.cc >/dev/null)
  then
    echo [source.cc changed] \
      diff -U 1 --minimal -p "$PREVIOUS_SOURCE_FILE" "$SOURCE_ARCHIVE_FILE"
  fi
  set -e
fi
cp -f source.cc $SOURCE_ARCHIVE_FILE

clang $CFLAGS -S -o output.S source.cc

PREVIOUS_OUTPUT_FILE="archive/output-$PREVIOUS_TIMESTAMP.S"
OUTPUT_ARCHIVE_FILE=archive/output-$SOURCE_TIMESTAMP.S
OUTPUT_DIFFTMP=
if [ ! -z $PREVIOUS_TIMESTAMP ] && [ -f $PREVIOUS_OUTPUT_FILE ]; then
  if [ "$PREVIOUS_OUTPUT_FILE" != "$OUTPUT_ARCHIVE_FILE" ] &&
     ! (diff -q "$PREVIOUS_OUTPUT_FILE" output.S >/dev/null)
  then
    OUTPUT_DIFFTMP=$(mktemp -t output.diff)
    set +e
    diff -U 0 --minimal "$PREVIOUS_OUTPUT_FILE" output.S > $OUTPUT_DIFFTMP
    OUTPUT_LINE_COUNT_DELTA=$(expr \
      $(cat $OUTPUT_DIFFTMP|grep ^+|wc -l) - $(cat $OUTPUT_DIFFTMP|grep ^-|wc -l))
    set -e
    echo [output.S changed] \
      diff -U 1 --minimal -F '^_.*:' "$PREVIOUS_OUTPUT_FILE" "$OUTPUT_ARCHIVE_FILE"
  fi
fi
cp -f output.S $OUTPUT_ARCHIVE_FILE

echo ./program
./program


if [ "$OUTPUT_DIFFTMP" != "" ]; then
  set +e
  diff -U 0 --minimal A B > $OUTPUT_DIFFTMP

  cost_delta=0

  while read line; do
    #echo line: $line
    sign=$(echo $line | cut -f 1 -d ' ')
    if [ "$sign" == "-" ] || [ "$sign" == "+" ]; then
      instruction_mnemonic=$(echo $line | cut -f 2 -d ' ')
      instruction_cost=1
      case $instruction_mnemonic in

      # ---- Integer instructions ----

      # Move instructions
      movz*)    instruction_cost=1 ;;
      movnt*)   instruction_cost=2 ;;
      movabs*)  instruction_cost=1 ;;
      mov*)     instruction_cost=1 ;;
        # Highly dependent on uop fusing and operands. C=1 for r,r/i/m/sr
      cmov*)    instruction_cost=1 ;;
      xchg*)    instruction_cost=5 ;; # average
        # depends on operands. C=3 for r,r. C=7 for r,m
      xlat)     instruction_cost=2 ;;
      push*)    instruction_cost=1 ;;
        # depend on operands. C=1 for r/i. C=2 for m/sr
      pop*)     instruction_cost=2 ;;
        # depend on operands. C=1 for r. C=3 for (E/R)SP. C=2 for m. C=7 for sr
      lea*)     instruction_cost=1 ;;
      bswap*)   instruction_cost=1 ;;
      lfence*)  instruction_cost=2 ;;
      mfence*)  instruction_cost=3 ;;
      sfence*)  instruction_cost=2 ;;

      # Arithmetic instructions

      # Logic instructions
      shld*|shrd*)    instruction_cost=2 ;; # depends on operands
      shl*|shr*)      instruction_cost=2 ;; # C=1 for r,i/cl. C=3 for m,i/cl.
      and*|or*|xor*)  instruction_cost=1 ;; # C=1 for r,r/i/m. C=2 for m,r/i.

      *) echo '?' $sign $instruction_mnemonic
      esac
      cost_delta=$(expr $cost_delta $sign $instruction_cost)
    fi
  done < $OUTPUT_DIFFTMP
  rm -f "$OUTPUT_DIFFTMP"
  echo "Output line count delta: $OUTPUT_LINE_COUNT_DELTA"
  echo "Instruction cost delta:  $cost_delta"
else
  echo "output.S: no difference from last version"
fi
