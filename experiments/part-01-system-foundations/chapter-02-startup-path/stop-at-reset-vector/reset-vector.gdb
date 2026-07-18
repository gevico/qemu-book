set pagination off
set confirm off
set architecture riscv:rv64
target remote :1234
printf "initial-pc="
output/x $pc
printf "\n"
info registers
x/8i $pc
stepi
printf "after-step-pc="
output/x $pc
printf "\n"
detach
quit
