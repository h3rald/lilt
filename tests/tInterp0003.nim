
include hinterp

test(
    """
    vowel: <aeiou>
    vowels: *$vowel
    nVowels: val=vowels
    """,
    "nVowels",
    "aeeoouuiaobbbbboisoso",
    ~~ {
        "kind": "nVowels",
        "val": "aeeoouuiao"
    }
)
