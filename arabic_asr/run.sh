#!/bin/bash
#: Title : run.sh
#: Author : "Ahmed Ismail" <ahmed.ismail.zahran@gmail.com>
#: Version : 1.0
#: Description : Build Aalto system for MGB-challenge.

. ./cmd.sh
. ./path.sh

nj=4
mfccdir=data/feats
whole_dir=data/whole
train_dir=data/train
train_dir_10000=data/train_10000
test_dir=data/test
lang_dir=data/lang


# ============= Feature extraction =============

# Extract MFCC's
steps/make_mfcc.sh --nj $nj --cmd "$train_cmd" $whole_dir exp/make_mfcc/whole \
    $mfccdir

# Split the data into training and test sets based on speakers

# First, select the test set such that it forms about 20% of the whole data set
num_utts=$(< $whole_dir/segments wc -l)
num_utts_test=$(echo "$num_utts * 0.15" | bc)
num_utts_test=${utts_num_test%.*}
utils/subset_data_dir.sh --speakers $whole_dir $num_utts_test $test_dir

# Remove the test speakers from the training set and run Kaldi's fix_data_dir
if [ -d $train_dir ]; then
    rm -r $train_dir
fi
cp -r $whole_dir $train_dir
python utils/remove_test_speakers.py $train_dir $test_dir

# Remove extra utterances in any files with Kaldi's fix_data_dir
utils/spk2utt_to_utt2spk.pl $train_dir/utt2spk > $train_dir/spk2utt
utils/validate_data_dir.sh $train_dir
utils/fix_data_dir.sh $train_dir

# Select 10,000 shortest utterances in the training set and use them to train a
# monophone GMM
utils/subset_data_dir.sh --shortest $train_dir 10000 $train_dir_10000

# Compute CMVN stats
steps/compute_cmvn_stats.sh $train_dir exp/make_mfcc/train $mfccdir
steps/compute_cmvn_stats.sh $test_dir exp/make_mfcc/test $mfccdir
steps/compute_cmvn_stats.sh $train_dir_10000 exp/make_mfcc/train_10000 $mfccdir

# Prepare language model directory
rm -r data/local/lang data/lang
rm data/local/dict/lexiconp.txt
utils/prepare_lang.sh data/local/dict "<UNK>" data/local/lang $lang_dir


# ============= Language model =============

# Transform Kaldi corpus to the format used by variKN
python3 utils/Kaldi_text2variKN_corpus.py data/train/text data/train/text_variKN

# Use variKN to produce Kneser-Ney smoothed n-gram model
python utils/Kaldi_lex2variKN_vocab.py data/local/dict/lexicon.txt data/local/vocab.txt
steps/produce_n_gram_lm.sh data/train/text_variKN data/local/vocab.txt data/local/lm_n_gram.arpa

# Use arpa to produce G.fst
arpa2fst --disambig-symbol=#0 --read-symbol-table=$lang_dir/words.txt data/local/lm_n_gram.arpa $lang_dir/G.fst


# ============= Monophone model =============

# Train a monophone Gaussian Mixture Model (GMM)

steps/train_mono.sh --nj $nj --cmd "$train_cmd" $train_dir_10000 $lang_dir exp/mono

# Build decoding graph for the monophone GMM
utils/mkgraph.sh $lang_dir exp/mono exp/mono/graph

# Decode using the monophone GMM
steps/decode.sh --nj $nj --cmd "$decode_cmd" exp/mono/graph data/test exp/mono/decode

# Extract alignments for the monophone GMM
steps/align_si.sh --nj $nj --cmd "$train_cmd" $train_dir_10000 $lang_dir exp/mono exp/mono_ali


# ============= Tri-phone model =============

# Train a tri-phone GMM using alignments generated by the previous model for initialization
steps/train_deltas.sh --cmd "$train_cmd" 2000 11000 $train_dir $lang_dir exp/mono_ali exp/tri1

# Build decoding graph
utils/mkgraph.sh $lang_dir exp/tri1 exp/tri1/graph

# Decode using triphone model
steps/decode.sh --nj $nj --cmd "$decode_cmd" exp/tri1/graph data/test exp/tri1/decode

# Extract alignments for the triphone model
steps/align_si.sh --nj $nj --cmd "$train_cmd" $train_dir $lang_dir exp/tri1 exp/tri1_ali


