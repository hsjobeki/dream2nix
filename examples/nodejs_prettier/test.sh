binDir="result/"
for entry in "$binDir"/*; do
    echo $(basename $entry)
done