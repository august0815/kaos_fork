#To compile kaos
#!/bin/bash
runhaskell Setup.lhs configure --prefix=/use/home/kaos --user -v

runhaskell Setup.lhs build -v

# sudo cp dist/build/kaos/kaos /usr/local/bin

