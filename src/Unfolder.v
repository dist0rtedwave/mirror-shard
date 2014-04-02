Require Import Arith Bool List.
Require Import ExtLib.Tactics.Consider.
Require Import Expr ExprUnify Folds.
Require Import SepExpr SepHeap Lemma SepLemma.
Require Import Prover.
Require Import Env.
Require Import Tactics ListFacts.

Set Implicit Arguments.
Set Strict Implicit.

Module Type Unfolder (ST : SepTheory.SepTheory)
                     (SE : SepExpr ST)
                     (SH : SepHeap ST SE)
                     (LEM : SepLemma.SepLemmaType ST SE).
  Module ST_EXT := SepTheory.SepTheory_Ext ST.

  Section parametric.
    Variable types : list type.
    Variable prover : ProverT.

    (* As we iterate through unfolding, we modify this sort of state. *)
    Record unfoldingState :=
    { Vars : variables
    ; UVars : variables
    ; Heap : SH.SHeap
    }.

    Definition hintSide := list LEM.sepLemma.

    Parameter refineForward : hintSide -> nat -> Facts prover ->
      unfoldingState -> unfoldingState * bool.

    Parameter refineBackward : hintSide -> nat -> Facts prover ->
      unfoldingState -> unfoldingState * bool.

    Variable funcs : functions types.
    Variable preds : SE.predicates types.

    Definition hintSideD := Forall (@LEM.sepLemmaD types funcs preds nil nil).

    Axiom refineForward_Length : forall hints bound facts P Q b,
      refineForward hints bound facts P = (Q,b) ->
      exists vars_ext (* meta_ext *),
        Vars Q = Vars P ++ vars_ext /\
        UVars Q = UVars P (* ++ meta_ext *).

    Axiom refineForward_WellTyped : forall hints bound facts P Q b,
      hintSideD hints ->
      ProverT_correct prover funcs ->
      refineForward hints bound facts P = (Q,b) ->
      SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
      SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.

    Axiom refineForward_Ok : forall hints bound facts P Q b,
      hintSideD hints ->
      ProverT_correct prover funcs ->
      forall PC : ProverT_correct prover funcs,
      refineForward hints bound facts P = (Q,b) ->
      forall meta_env vars_env,
        WellTyped_env (UVars P) meta_env -> (** meta_env instantiates the uvars **)
        WellTyped_env (Vars P) vars_env ->
        forall (WT : SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true),
        Valid PC meta_env vars_env facts ->
        ST.himp
           (SE.sexprD funcs preds meta_env vars_env (SH.sheapD (Heap P)))
           (ST_EXT.existsEach (skipn (length vars_env) Q.(Vars)) (fun vars_ext : list { t : tvar & tvarD types t } =>
              (SE.sexprD funcs preds meta_env (vars_env ++ vars_ext) (SH.sheapD (Heap Q))))).

    Axiom refineBackward_Length : forall hints bound facts P Q b,
      refineBackward hints bound facts P = (Q,b) ->
      exists meta_ext,
        Vars Q = Vars P /\
        UVars Q = UVars P ++ meta_ext.

    Axiom refineBackward_WellTyped : forall hints bound facts P Q b,
      hintSideD hints ->
      ProverT_correct prover funcs ->
        refineBackward hints bound facts P = (Q,b) ->
        SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
        SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.

    Axiom refineBackward_Ok : forall hints bound facts P Q meta_env vars_env b,
      hintSideD hints ->
      ProverT_correct prover funcs ->
      forall PC : ProverT_correct prover funcs,
      refineBackward hints bound facts P = (Q,b) ->
      WellTyped_env (UVars P) meta_env -> (** meta_env instantiates the uvars **)
      WellTyped_env (Vars P) vars_env ->
      SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
      Valid PC meta_env vars_env facts ->
      ST.himp (ST_EXT.existsEach (skipn (length meta_env) Q.(UVars)) (fun meta_ext : env types =>
                      (SE.sexprD funcs preds (meta_env ++ meta_ext) vars_env (SH.sheapD (Heap Q)))))
                    (SE.sexprD funcs preds meta_env vars_env (SH.sheapD (Heap P))).
  End parametric.
End Unfolder.

Module Make (ST : SepTheory.SepTheory)
            (SE : SepExpr ST)
            (Import SH : SepHeap ST SE)
            (SUBST : Instantiation.Subst)
            (U : SyntacticUnifier SUBST)
            (LEM : SepLemma.SepLemmaType ST SE)
            <: Unfolder ST SE SH LEM.

  Module Import HEAP_FACTS := SepHeapFacts ST SE SH.
  Module ST_EXT := SepTheory.SepTheory_Ext ST.

  Section env.
    Variable types : list type.
    Variable funcs : functions types.
    Variable preds : SE.predicates types.

    (** * Some substitution functions *)

    Section openForUnification.
      Variable U : nat. (** **)

      Definition ERROR : expr.
      refine (Var 0).
      Qed.
      
      Fixpoint openForUnification (e : expr) : expr :=
        match e with
          | Var v => UVar (U + v)
          | UVar _ => e (** contradiction **)
          | Expr.Func f es => Expr.Func f (List.map openForUnification es)
          | Equal t l r => Equal t (openForUnification l) (openForUnification r)
          | Not e => Not (openForUnification e)
        end.

    End openForUnification.

    Section instantiate.
      Variable doQuant : nat -> expr.
      Variable U_or_G : bool.
      Variable U : nat.
      Variable G : nat.
      Variable G' : nat.
      Variable sub : SUBST.Subst.
      
      Fixpoint liftInstantiate (e : expr) : expr :=
        match e with
          | Var v => 
            if NPeano.ltb v G' then (if U_or_G then UVar (v + U) else Var (v + G))
            else let idx := U + v - G' in
                 match SUBST.Subst_lookup idx sub with
                   | None => UVar idx (** contradiction **)
                   | Some e => e
                 end
          | UVar v => match SUBST.Subst_lookup v sub with (** contradiction **)
                        | None => UVar v
                        | Some e => e
                      end
          | Expr.Func f es => Expr.Func f (List.map liftInstantiate es)
          | Equal t l r => Equal t (liftInstantiate l) (liftInstantiate r)
          | Not e => Not (liftInstantiate e)
        end.

    End instantiate.

    (** Preprocessed databases of hints *)
    Definition hintSide := list LEM.sepLemma.
    (* A complete set of unfolding hints of a single sidedness (see below) *)

    Definition hintSideD := Forall (@LEM.sepLemmaD types funcs preds nil nil).

    Record hintsPayload := {
      Forward : hintSide;
      (* Apply on the lefthand side of an implication *)
      Backward : hintSide
      (* Apply on the righthand side *)
    }.

    Definition default_hintsPayload : hintsPayload :=
      {| Forward := nil
       ; Backward := nil
       |}.

    Definition composite_hintsPayload (l r : hintsPayload) : hintsPayload :=
      {| Forward := Forward l ++ Forward r
       ; Backward := Backward l ++ Backward r
       |}.

    Record hintsSoundness (Payload : hintsPayload) : Prop := {
      ForwardOk : hintSideD (Forward Payload);
      BackwardOk : hintSideD (Backward Payload)
    }.

    Theorem hintsSoundness_default : hintsSoundness default_hintsPayload.
    Proof.
      econstructor; constructor.
    Qed.

    Theorem hintsSoundness_composite l r (L : hintsSoundness l) (R : hintsSoundness r)
      : hintsSoundness (composite_hintsPayload l r).
    Proof.
      econstructor; simpl; eapply Folds.Forall_app; solve [ eapply ForwardOk; auto | eapply BackwardOk; auto ].
    Qed.

    (** Applying up to a single hint to a hashed separation formula *)

    Fixpoint find A B (f : A -> option B) (ls : list A) : option B :=
      match ls with
        | nil => None
        | x :: ls' => match f x with
                        | None => find f ls'
                        | v => v
                      end
      end.

    Lemma findOk : forall A B (f : A -> option B) ls res,
      find f ls = Some res ->
      exists a, In a ls /\ f a = Some res.
    Proof.
      clear. induction ls; intros; simpl in *; try congruence.
      revert H. consider (f a); intros. inversion H0; subst; exists a; intuition.
      eapply IHls in H0. destruct H0; intuition. eauto.
    Qed.

    Fixpoint findWithRest' A B (f : A -> list A -> option B) (ls acc : list A) : option B :=
      match ls with
        | nil => None
        | x :: ls' => match f x (rev_append acc ls') with
                        | None => findWithRest' f ls' (x :: acc)
                        | v => v
                      end
      end.

    Lemma findWithRest'Ok : forall A B (f : A -> list A -> option B) ls acc res,
      findWithRest' f ls acc = Some res ->
      exists xs x xs', ls = xs ++ x :: xs' /\ f x (rev acc ++ xs ++ xs') = Some res.
    Proof.
      clear.
      induction ls; intros; simpl in *; try congruence.
      revert H; consider (f a (rev_append acc ls)); intros.
      inversion H0; clear H0; subst. exists nil. exists a. exists ls. simpl. rewrite rev_append_rev in H; auto.
      eapply IHls in H0. do 3 destruct H0. intuition. subst. clear H. simpl in *. rewrite app_ass in H2. simpl in *.
      exists (a :: x). simpl. exists x0. exists x1. intuition.
    Qed.

    Definition findWithRest A B (f : A -> list A -> option B) (ls : list A) : option B :=
      findWithRest' f ls nil.

    Lemma findWithRestOk : forall A B (f : A -> list A -> option B) ls res,
      findWithRest f ls = Some res ->
      exists xs x xs', ls = xs ++ x :: xs' /\ f x (xs ++ xs') = Some res.
    Proof.
      clear. unfold findWithRest; simpl. intros. eapply findWithRest'Ok in H. eauto.
    Qed.

    (* As we iterate through unfolding, we modify this sort of state. *)
    Record unfoldingState :=
    { Vars : variables
    ; UVars : variables
    ; Heap : SH.SHeap
    }.

    Section unfoldOne.
      Variable unify_bound : nat.
      
      Variable prover : ProverT.
      (* This prover must discharge all pure obligations of an unfolding lemma, if it is to be applied. *)
      Variable facts : Facts prover.

      Variable hs : hintSide.
      (* Use these hints to unfold impure predicates. *)

      Fixpoint Subst_to_env U G (s : SUBST.Subst) (ts : variables) (cur : uvar) : option (env types) :=
        match ts with
          | nil => Some nil
          | t :: ts =>
            match SUBST.Subst_lookup cur s with
              | None => None
              | Some e =>
                match Subst_to_env U G s ts (S cur) with
                  | None => None
                  | Some env =>
                    match exprD funcs U G e t with
                      | None => None
                      | Some v => Some (@existT _ _ t v :: env)
                    end
                end
            end
        end.

      Fixpoint checkAllInstantiated (from : nat) (ts : variables) (sub : SUBST.Subst) : bool :=
        match ts with
          | nil => true
          | _ :: ts => if SUBST.Subst_lookup from sub then checkAllInstantiated (S from) ts sub else false
        end.

      (** Determine if a lemma is applicable.
       ** - [firstUVar] an index larger than the largest unification variable
       ** - [lem] is the lemma to apply
       ** - [args] is the outside
       ** - [key] is the patterns (closed by [Foralls lem]) that need to unify with [args])
       **)
      Definition applicable U_or_G (firstUvar firstVar : nat) (lem : LEM.sepLemma) (args key : exprs) 
        : option SUBST.Subst :=
        let numForalls := length (Lemma.Foralls lem) in
        (** NOTE: it is important that [key] is first because of the way the unification algorithm works **)
        match fold_left_2_opt (U.exprUnify unify_bound) (map (openForUnification firstUvar) key) args SUBST.Subst_empty with
          | None => None
          | Some subst =>
            if EqNat.beq_nat (SUBST.Subst_size subst) numForalls && checkAllInstantiated firstUvar (Lemma.Foralls lem) subst
            then (* Now we must make sure all of the lemma's pure obligations are provable. *)
                 if allb (Prove prover facts) (map (liftInstantiate U_or_G firstUvar firstVar 0 subst) (Lemma.Hyps lem))
                 then Some subst
                 else None
            else None
        end.

      (* Returns [None] if no unfolding opportunities are found.
       * Otherwise, return state after one unfolding. *)
      Definition unfoldForward (s : unfoldingState) : option unfoldingState :=
        let imps := SH.impures (Heap s) in
        let firstUvar  := length (UVars s) in
        let firstVar   := length (Vars s) in
        find (fun h =>
          match LEM.Lhs h with
            | SE.Func f args' =>
              match FM.find f imps with
                | None => None
                | Some argss =>
                  let numForalls := length (Lemma.Foralls h) in
                  findWithRest (fun args argss =>
                    (* We must tweak the arguments by substituting unification variables for
                     * [forall]-quantified variables from the lemma statement. *)
                    match applicable false firstUvar firstVar h args args' with
                      | None => None
                      | Some subs =>
                        (* Remove the current call from the state, as we are about to replace
                         * it with a simplified set of pieces. *)
                        let impures' := FM.add f argss (impures (Heap s)) in
                        let sh := Build_SHeap impures'
                                              (pures (Heap s))
                                              (other (Heap s)) in

                        (* Time to hash the hint RHS, to (among other things) get the new existential variables it creates. *)
                        let (exs, sh') := hash (LEM.Rhs h) in

                        (* Apply the substitution that unification gave us. *)
                        let sh' := applySHeap (liftInstantiate false firstUvar firstVar (length exs) subs) sh' in

                        (* The final result is obtained by joining the hint RHS with the original symbolic heap. *)
                        Some {| Vars := Vars s ++ rev exs
                              ; UVars := UVars s
                              ; Heap := star_SHeap sh sh'
                              |}
                    end
                  ) argss
              end
            | _ => None
          end) hs.

      Definition unfoldBackward (s : unfoldingState) : option unfoldingState :=
        let imps       := SH.impures (Heap s) in
        let firstUvar  := length (UVars s) in
        let firstVar   := length (Vars s) in
        find (fun h =>
          match LEM.Rhs h with
            | SE.Func f args' =>
              match FM.find f imps with
                | None => None
                | Some argss =>
                  findWithRest (fun args argss =>
                    match applicable true firstUvar firstVar h args args' with
                      | None => None
                      | Some subs =>
                        (* Remove the current call from the state, as we are about to replace it with a
                         * simplified set of pieces. *)
                        let impures' := FM.add f argss (impures (Heap s)) in
                        let sh := Build_SHeap impures'
                                              (pures (Heap s))
                                              (other (Heap s)) in

                        (* Time to hash the hint LHS, to (among other things) get the new existential variables it creates. *)
                        let (exs, sh') := hash (LEM.Lhs h) in

                        (* Newly introduced variables must be replaced with unification variables, and
                         * universally quantified variables must be substituted for. *)
                        let sh' := applySHeap (liftInstantiate true firstUvar firstVar (length exs) subs) sh' in

                        (* The final result is obtained by joining the hint LHS with the original symbolic heap. *)
                        Some {| Vars := Vars s
                              ; UVars := UVars s ++ rev exs
                              ; Heap := star_SHeap sh sh'
                              |}
                    end
                  ) argss
              end
            | _ => None
          end) hs.

    End unfoldOne.

    Section unfolder.
      Definition unify_bound := 5.
      Variable hs : hintSide.
      Variable prover : ProverT.

      (* Perform up to [bound] simplifications, based on [hs]. *)
      Fixpoint forward (bound : nat) (facts : Facts prover) (s : unfoldingState) : unfoldingState * nat :=
        match bound with
          | O => (s, bound)
          | S bound' =>
            match unfoldForward unify_bound prover facts hs s with
              | None => (s, bound)
              | Some s' => forward bound' facts s'
            end
        end.

      Fixpoint backward (bound : nat) (facts : Facts prover) (s : unfoldingState) : unfoldingState * nat :=
        match bound with
          | O => (s, bound)
          | S bound' =>
            match unfoldBackward unify_bound prover facts hs s with
              | None => (s, bound)
              | Some s' => backward bound' facts s'
            end
        end.

      Hypothesis hsOk : hintSideD hs.
      Hypothesis PC : ProverT_correct prover funcs.

      Lemma Subst_to_env_env : forall U G S' TS cur e0,
        Subst_to_env U G S' TS cur = Some e0 ->
        map (@projT1 _ _) e0 = TS.
      Proof.
        induction TS; simpl; intros;
          repeat match goal with
                   | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
                   | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                     revert H ; case_eq X ; intros; try congruence
                   | [ |- _ ] => progress ( simpl in * )
                   | [ |- _ ] => progress subst
                 end; try solve [ intuition ].
        f_equal. eauto.
      Qed.

      Require Import ExtLib.Tactics.EqDep.

      Lemma Subst_to_env_nth_error_lookup : forall F U G sub x v CUR,
        Subst_to_env U G sub (typeof_env F) CUR = Some F ->
        nth_error F x = Some v ->
        exists e, SUBST.Subst_lookup (CUR + x) sub = Some e /\
          exprD funcs U G e (projT1 v) = Some (projT2 v).
      Proof.
        induction F; simpl; intros; think.
        { destruct x; simpl in *; unfold error in *; congruence. }
        { destruct a; simpl in *. think. apply inj_pair2 in H5. subst.
          destruct x; simpl in *.
          { inversion H0; clear H0; subst. rewrite Plus.plus_0_r. eexists; intuition eauto. }
          { rewrite Plus.plus_comm. simpl. rewrite Plus.plus_comm. eapply IHF in H1. simpl in H1. eapply H1. auto. } }
      Qed.
      Lemma Subst_to_env_typeof_env : forall U G sub ts CUR F,
        Subst_to_env U G sub ts CUR = Some F ->
        ts = typeof_env F.
      Proof.
        induction ts; simpl; intros.
        { think. reflexivity. }
        { consider (Subst_to_env U G sub ts (S CUR)). intros. eapply IHts in H. think. simpl. auto.
          intros; think. }
      Qed.

      Lemma nth_error_typeof_funcs : forall f t s,
        nth_error (typeof_funcs funcs) f = Some t ->
        nth_error funcs f = Some s ->
        TRange t = Range s /\ TDomain t = Domain s.
      Proof.
        unfold typeof_funcs. intros. erewrite map_nth_error in H by eauto. think. unfold typeof_sig; intuition.
      Qed.

      Theorem openForUnification_spec : forall F U G e t ,
        is_well_typed (typeof_funcs funcs) nil (typeof_env F) e t = true ->
        exprD funcs nil F e t = exprD funcs (U ++ F) G (openForUnification (length U) e) t.
      Proof.
        induction e; simpl; unfold lookupAs; intros; think;
          repeat match goal with
                   | [ H : nth_error _ _ = Some _ |- _ ] =>
                     eapply WellTyped_env_nth_error_Some in H; [ | solve [ eauto using typeof_env_WellTyped_env ] ] ; destruct H
                   | [ |- _ ] => rewrite nth_error_app_R by omega
                   | [ |- _ ] => rewrite nth_error_app_L by omega
                   | [ H : nth_error ?L ?n = _ |- context [ nth_error ?L ?n' ] ] =>
                     cutrewrite (n' = n); [ | omega ]
                   | [ H : nth_error nil ?X = Some _ |- _ ] =>
                     clear - H ; abstract (exfalso ; destruct X ; simpl in *; unfold error in *; congruence)
                   | [ |- match ?X with _ => _ end = match ?X with _ => _ end ] =>
                     consider X; intros; try reflexivity
                 end; think; auto.
        { unfold typeof_funcs in H0. rewrite map_nth_error_full in H0. rewrite H3 in H0. inversion H0; clear H0; subst.
          destruct s; simpl in *; subst; clear - H H2. rewrite applyD_map.
          revert H2. generalize dependent Domain. clear - H.
          induction H; destruct Domain; intros; simpl in *; think; auto.
          consider (exprD funcs (U ++ F) G (openForUnification (length U) x) t); intros; auto. }
      Qed.

      Theorem openForUnification_typed : forall F U G e t ,
        is_well_typed (typeof_funcs funcs) nil F e t = true ->
        is_well_typed (typeof_funcs funcs) (U ++ F) G (openForUnification (length U) e) t = true.
      Proof.
        induction e; simpl; unfold lookupAs; intros; think;
          repeat match goal with
                   | [ H : nth_error _ _ = Some _ |- _ ] =>
                     eapply WellTyped_env_nth_error_Some in H; [ | solve [ eauto using typeof_env_WellTyped_env ] ] ; destruct H
                   | [ |- _ ] => rewrite nth_error_app_R by omega
                   | [ |- _ ] => rewrite nth_error_app_L by omega
                   | [ H : nth_error ?L ?n = _ |- context [ nth_error ?L ?n' ] ] =>
                     cutrewrite (n' = n); [ | omega ]
                   | [ H : nth_error nil ?X = Some _ |- _ ] =>
                     clear - H ; abstract (exfalso ; destruct X ; simpl in *; unfold error in *; congruence)
                   | [ |- match ?X with _ => _ end = match ?X with _ => _ end ] =>
                     consider X; intros; try reflexivity
                 end; think; auto.
        { rewrite tvar_seqb_refl. reflexivity. }
        { destruct t0; simpl in *. clear H0. generalize dependent TDomain. induction H; destruct TDomain; simpl in *; auto.
          intros; think; auto. }
      Qed.

      Definition quant T (b : bool) (B E : list T) : list T := if b then B ++ E else B.

      Require Import ExtLib.Core.EquivDec.

      Theorem liftInstantiate_spec : forall U_or_G U G G' F e t sub ts,
          is_well_typed (typeof_funcs funcs) nil (typeof_env G' ++ typeof_env F) e t = true ->
          Subst_to_env U G sub ts (length U) = Some F ->
          exprD funcs nil (G' ++ F) e t =
          exprD funcs (quant U_or_G U G') (quant (negb U_or_G) G G') (liftInstantiate U_or_G (length U) (length G) (length G') sub e) t.
      Proof.
        induction e; repeat progress (simpl in *; unfold lookupAs in *; intros;
          repeat match goal with
                   | [ H : nth_error _ _ = Some _ |- _ ] =>
                     eapply WellTyped_env_nth_error_Some in H; [ | solve [ eauto using typeof_env_WellTyped_env ] ] ; destruct H
                   | [ |- _ ] => rewrite nth_error_app_R by (try rewrite typeof_env_length in *; omega)
                   | [ |- _ ] => rewrite nth_error_app_L by (try rewrite typeof_env_length in *; omega)
                   | [ |- _ ] => rewrite nth_error_app_R in * by (try rewrite typeof_env_length in *; omega)
                   | [ |- _ ] => rewrite nth_error_app_L in * by (try rewrite typeof_env_length in *; omega)
                   | [ H : nth_error ?L ?n = _ |- context [ nth_error ?L ?n' ] ] =>
                     cutrewrite (n' = n); [ | omega ]
                   | [ H : nth_error nil ?X = Some _ |- _ ] =>
                     clear - H ; abstract (exfalso ; destruct X ; simpl in *; unfold error in *; congruence)
                   | [ |- match ?X with _ => _ end = match ?X with _ => _ end ] =>
                     consider X; intros; try reflexivity
                   | [ |- context [ NPeano.ltb ?X ?Y ] ] => consider (NPeano.ltb X Y); intros
                 end; think); auto.
        { rewrite EquivDec_refl_left. destruct U_or_G; simpl; unfold lookupAs; simpl;
          rewrite nth_error_app_R by omega. cutrewrite (x + length U - length U = x); [ | omega ].
          rewrite H. simpl. rewrite EquivDec_refl_left. auto.
          cutrewrite (x + length G - length G = x); [ | omega ]; rewrite H. simpl. rewrite EquivDec_refl_left. auto. }
        { rewrite typeof_env_length in *. rewrite H. simpl. rewrite EquivDec_refl_left.
          generalize (Subst_to_env_typeof_env _ _ _ _ _ H0); intros; subst.
          eapply Subst_to_env_nth_error_lookup in H; eauto. destruct H. intuition.
          cutrewrite (length U + x - length G' = length U + (x - length G')); [ | omega ]. rewrite H2.
          simpl in *. symmetry; destruct U_or_G; simpl.
          rewrite <- app_nil_r with (l := G); eauto using exprD_weaken.
          rewrite <- app_nil_r with (l := U); eauto using exprD_weaken. }
        { unfold typeof_funcs in H0; rewrite map_nth_error_full in H0. rewrite H2 in H0. inversion H0; clear H0; subst.
          destruct s; simpl in *. revert H5 H1. clear - H. generalize dependent Domain.
          induction H; destruct Domain; simpl in *; intros; think; auto.
          erewrite <- H; eauto. destruct (exprD funcs nil (G' ++ F) x t); auto. }
      Qed.

      Lemma checkAllInstantiated_app : forall sub ts ts' from,
        checkAllInstantiated from (ts ++ ts') sub =
        checkAllInstantiated from ts sub && checkAllInstantiated (length ts + from) ts' sub.
      Proof.
        clear. induction ts; simpl; intros; think; eauto; simpl.
        consider (SUBST.Subst_lookup from sub); intros; auto.
        f_equal. rewrite Plus.plus_comm. simpl. rewrite Plus.plus_comm. reflexivity.
      Qed.

      Lemma checkAllInstantiated_dropU : forall tU tG sub ts ts',
        checkAllInstantiated (length tU) ts sub = true ->
        SUBST.Subst_WellTyped (typeof_funcs funcs) (tU ++ ts ++ ts') tG sub ->
        forall e t n,
          n >= length tU ->
          is_well_typed (typeof_funcs funcs) (tU ++ ts) tG e t = true ->
          SUBST.Subst_lookup n sub = Some e ->
          is_well_typed (typeof_funcs funcs) tU tG e t = true.
      Proof.
        clear. induction ts using rev_ind; simpl; intros; think; eauto.
        rewrite app_nil_r in *. auto.
        rewrite checkAllInstantiated_app in H. simpl in *; think.
        eapply IHts; eauto. rewrite app_ass in H0. simpl in *; eauto.
        eapply is_well_typed_not_mentionsU_last. rewrite app_ass. eassumption.
        eapply SUBST.exprInstantiate_Removes. rewrite app_length. rewrite Plus.plus_comm; eauto.
        instantiate (1 := e). eapply SUBST.exprInstantiate_instantiated. eauto.
      Qed.

      Lemma checkAllInstantiated_domain : forall sub F cU,
        checkAllInstantiated cU F sub = true ->
        forall u, cU <= u -> u < cU + length F -> SUBST.Subst_lookup u sub <> None.
      Proof.
        clear. induction F; simpl in *; intros; think. exfalso. omega.
        consider (EqNat.beq_nat cU u); intros. subst.
        intro. congruence. eapply IHF; eauto. omega. omega.
      Qed.


      Theorem liftInstantiate_typed : forall U_or_G U G G' e t sub F,
        is_well_typed (typeof_funcs funcs) nil (G' ++ F) e t = true ->
        SUBST.Subst_WellTyped (typeof_funcs funcs) (U ++ F) G sub ->
        checkAllInstantiated (length U) F sub = true ->
        is_well_typed (typeof_funcs funcs) (quant U_or_G U G') (quant (negb U_or_G) G G')
          (liftInstantiate U_or_G (length U) (length G) (length G') sub e) t = true.
      Proof.
        clear. induction e; repeat progress (simpl in *; unfold lookupAs in *; intros;
          repeat match goal with
                   | [ H : nth_error _ _ = Some _ |- _ ] =>
                     eapply WellTyped_env_nth_error_Some in H; [ | solve [ eauto using typeof_env_WellTyped_env ] ] ; destruct H
                   | [ |- _ ] => rewrite nth_error_app_R by (try rewrite typeof_env_length in *; omega)
                   | [ |- _ ] => rewrite nth_error_app_L by (try rewrite typeof_env_length in *; omega)
                   | [ |- _ ] => rewrite nth_error_app_R in * by (try rewrite typeof_env_length in *; omega)
                   | [ |- _ ] => rewrite nth_error_app_L in * by (try rewrite typeof_env_length in *; omega)
                   | [ H : nth_error ?L ?n = _ |- context [ nth_error ?L ?n' ] ] =>
                     cutrewrite (n' = n); [ | omega ]
                   | [ H : nth_error nil ?X = Some _ |- _ ] =>
                     clear - H ; abstract (exfalso ; destruct X ; simpl in *; unfold error in *; congruence)
                   | [ |- match ?X with _ => _ end = match ?X with _ => _ end ] =>
                     consider X; intros; try reflexivity
                   | [ |- context [ NPeano.ltb ?X ?Y ] ] => consider (NPeano.ltb X Y); intros
                 end; think); auto.
        { destruct U_or_G; simpl; rewrite nth_error_app_R by omega.
          cutrewrite (x + length U - length U = x); [ | omega ]. rewrite H. rewrite tvar_seqb_refl; auto.
          cutrewrite (x + length G - length G = x); [ | omega ]. rewrite H. rewrite tvar_seqb_refl; auto. }
        { consider (SUBST.Subst_lookup (length U + x - length G') sub); intros.
          generalize H4. eapply SUBST.WellTyped_lookup in H4; eauto. destruct H4. intuition.
          assert (is_well_typed (typeof_funcs funcs) U G e x0 = true).
          { eapply checkAllInstantiated_dropU. eauto. instantiate (1 := nil). rewrite app_nil_r. auto.
            2: eauto. 2: eauto. omega. }
          clear H7.
          rewrite nth_error_app_R in H6 by omega.
          cutrewrite (length U + x - length G' - length U = x - length G') in H6; [ | omega ].
          rewrite H in H6; inversion H6; clear H6; subst. destruct U_or_G; simpl.
          rewrite <- app_nil_r with (l := G); eapply is_well_typed_weaken; eauto.
          rewrite <- app_nil_r with (l := U); eapply is_well_typed_weaken; eauto.

          simpl. exfalso. apply nth_error_Some_length in H. eapply checkAllInstantiated_domain in H1.
          apply H1. eassumption. omega. omega. }
        { rewrite all2_map_1. destruct t0. clear H0. simpl in *. generalize dependent TDomain.
          induction H; destruct TDomain; simpl in *; intros; think; auto. }
      Qed.



      Lemma openForUnification_liftInstantiate : forall quant sub U G e,
        SUBST.exprInstantiate sub (openForUnification U e) = liftInstantiate quant U G 0 sub e.
      Proof.
        induction e; simpl; intros; think;
          repeat (rewrite SUBST.exprInstantiate_Equal || 
                  rewrite SUBST.exprInstantiate_Func || 
                  rewrite SUBST.exprInstantiate_Not ||
                  rewrite SUBST.exprInstantiate_Var ||
                  rewrite SUBST.exprInstantiate_UVar);
          think; auto.
        { rewrite <- minus_n_O. reflexivity. }
        { clear - H. f_equal. induction H; simpl; intros; think; auto. }
      Qed.

      Lemma typeof_funcs_WellTyped_funcs_eq : forall tfuncs funcs,
        WellTyped_funcs (types := types) tfuncs funcs ->
        tfuncs = typeof_funcs funcs.
      Proof.
        clear. induction 1; auto. simpl. f_equal; auto. unfold WellTyped_sig, typeof_sig in *.
        destruct r; destruct l; intuition; f_equal; auto.
      Qed.

      Lemma Subst_to_env_app : forall U G sub ts ts' from,
        Subst_to_env U G sub (ts ++ ts') from =
        match Subst_to_env U G sub ts from , Subst_to_env U G sub ts' (length ts + from) with
          | Some l , Some r => Some (l ++ r)
          | _ , _ => None
        end.
      Proof.
        induction ts; intros; simpl; think; auto.
        destruct (Subst_to_env U G sub ts' from); auto.
        cutrewrite (S (length ts + from) = length ts + S from); [ | omega ].
        repeat match goal with
                 | [ |- context [ match ?X with _ => _ end ] ] =>
                   match X with
                     | match _ with _ => _ end => fail 1
                     | _ => destruct X
                   end
               end; auto.
      Qed.

      Lemma checkAllInstantiated_Subst_to_env_success : forall U G tU tG,
        WellTyped_env tU U ->
        WellTyped_env tG G ->
        WellTyped_funcs (typeof_funcs funcs) funcs ->
        forall sub ts ts',
          checkAllInstantiated (length tU) (ts ++ ts') sub = true ->
          SUBST.Subst_WellTyped (typeof_funcs funcs) (tU ++ ts ++ ts') tG sub ->
          exists env, Subst_to_env U G sub ts (length tU) = Some env.
      Proof.
        clear; induction ts using rev_ind; simpl; intros; think; eauto.
        { rewrite app_ass in *. simpl in *. generalize H2. eapply IHts in H2. 2: eauto.
          destruct H2. rewrite Subst_to_env_app. rewrite H2. simpl.
          intro XX. generalize XX. rewrite checkAllInstantiated_app in XX. simpl in XX. think.
          generalize H5. eapply SUBST.WellTyped_lookup in H5; eauto. destruct H5. intuition.
          eapply checkAllInstantiated_dropU in XX. 5: eapply H7. 4: eauto.
          3: omega. Focus 2. instantiate (1 := nil). repeat rewrite app_ass. simpl. rewrite app_nil_r. auto.
          repeat rewrite nth_error_app_R in H8 by omega. repeat rewrite typeof_env_length in H8.
          cutrewrite (length ts + length U - length U - length ts = 0) in H8; [ | omega ]. inversion H8. subst.
          eapply is_well_typed_correct in XX.
          4: eauto. 2: unfold WellTyped_env in *; auto. 2: unfold WellTyped_env in *; auto.
          destruct XX. rewrite H5. eauto. }
      Qed.


      (** TODO: lift this outside **)
      Lemma fold_left_2_opt_unify : forall tU tG ts args args' sub sub',
        SUBST.Subst_WellTyped (typeof_funcs funcs) tU tG sub -> 
        all2 (is_well_typed (typeof_funcs funcs) tU tG) args ts = true ->
        all2 (is_well_typed (typeof_funcs funcs) tU tG) args' ts = true ->
        fold_left_2_opt (U.exprUnify unify_bound) args args' sub = Some sub' ->
        SUBST.Subst_WellTyped (typeof_funcs funcs) tU tG sub' /\
        SUBST.Subst_Extends sub' sub /\
        map (SUBST.exprInstantiate sub') args = map (SUBST.exprInstantiate sub') args'.
      Proof.
        clear. induction ts; destruct args; destruct args'; intros; simpl in *; think;
        try (congruence || solve [ intuition (eauto; reflexivity) ]).
        do 2 generalize H2. apply U.exprUnify_sound_syn in H2. intro. eapply U.exprUnify_Extends in H6.
        intro. eapply U.exprUnify_WellTyped in H7; eauto. eapply IHts in H3; eauto. destruct H3.
        intuition. etransitivity; eauto. rewrite H10. f_equal.
        assert (SUBST.exprInstantiate sub' (SUBST.exprInstantiate s e) = SUBST.exprInstantiate sub' (SUBST.exprInstantiate s e0)).
        rewrite H2. reflexivity. repeat rewrite SUBST.exprInstantiate_Extends in H8 by eauto. auto.
      Qed.

      Lemma exprD_weaken_quant : forall U U' G G' ug ug' a t v,
        exprD funcs U G a t = Some v ->
        exprD funcs (quant ug U U') (quant ug' G G') a t = Some v.
      Proof.
        clear; destruct ug; destruct ug'; simpl; intros;
          [ | rewrite <- app_nil_r with (l := G) | rewrite <- app_nil_r with (l := U) | auto ];
          apply exprD_weaken; auto.
      Qed.

      Lemma liftInstantiate_lemmaD : forall U_or_G U G lem sub env,
        Subst_to_env U G sub (Foralls lem) (length U) = Some env ->
        LEM.sepLemmaD funcs preds nil nil lem ->
        implyEach funcs (map (liftInstantiate U_or_G (length U) (length G) 0 sub) (Hyps lem)) U G
                 (SE.himp funcs preds nil env (LEM.Lhs lem) (LEM.Rhs lem)).
      Proof.
        clear. destruct 2; simpl in *. eapply forallEachR_sem in H1; eauto using Subst_to_env_env.
        eapply implyEach_sem. intros. eapply implyEach_sem in H1; eauto.

        clear H1. unfold WellTyped_lemma in *. think. generalize dependent (Hyps lem).
        induction l; simpl; intros; auto. think. intuition. clear H4 H6.
        unfold Provable in *.
        generalize (liftInstantiate_spec U_or_G U G nil (F := env)). simpl. erewrite <- Subst_to_env_typeof_env by eassumption.
        intro. eapply H4 in H; eauto. rewrite H.
        consider (exprD funcs U G (liftInstantiate U_or_G (length U) (length G) 0 sub a) tvProp); try contradiction; intros.
        erewrite exprD_weaken_quant by eauto. auto.
      Qed.
      Lemma allb_AllProvable : forall U G facts hyps,
        Valid PC U G facts ->
        allb (fun x => is_well_typed (typeof_funcs funcs) (typeof_env U) (typeof_env G) x tvProp) hyps = true ->
        allb (Prove prover facts) hyps = true ->
        AllProvable funcs U G hyps.
      Proof.
        clear. induction hyps; simpl; intros; think; auto.
        intuition; eauto.
        Require Import MirrorShard.Prover.
        eapply ProverCorrect_ProverCorrect'.
        eapply Prove_correct; eauto. eauto. eauto. unfold ValidProp.
        eapply is_well_typed_correct; eauto using typeof_env_WellTyped_env, typeof_funcs_WellTyped_funcs.
      Qed.

      Opaque SUBST.exprInstantiate.

      Lemma exprInstantiate_noop : forall sub (e : expr),
        (forall u, mentionsU u e = true -> SUBST.Subst_lookup u sub = None) ->
        SUBST.exprInstantiate sub e = e.
      Proof.
        clear; induction e; simpl in *; intros;
          repeat (rewrite SUBST.exprInstantiate_Equal || 
                  rewrite SUBST.exprInstantiate_Func || 
                  rewrite SUBST.exprInstantiate_Not ||
                  rewrite SUBST.exprInstantiate_Var ||
                  rewrite SUBST.exprInstantiate_UVar); think; try congruence; auto.
        { rewrite H; auto. consider (beq_nat x x); auto. }
        { f_equal. revert H0. induction H; simpl; intros; think; auto.
          erewrite IHForall; try erewrite H; eauto; intros; eapply H1; think; auto using orb_true_r. }
        { erewrite IHe1; try erewrite IHe2; eauto; intros; eapply H; think; auto using orb_true_r. }
      Qed.

      Fixpoint fromTo (start count : nat) : list nat :=
        match count with
          | 0 => nil
          | S count => start :: fromTo (S start) count
        end.

      Lemma fromTo_length : forall b a, length (fromTo a b) = b.
      Proof.
        clear; induction b; simpl; intros; eauto.
      Qed.

      Lemma fromTo_none_less : forall b a c,
        c < a -> ~In c (fromTo a b).
      Proof.
        clear; induction b; simpl; intros; auto. intro. destruct H0. omega. eapply IHb. 2: eauto. omega.
      Qed.

      Lemma checkAllInstantiated_perm : forall sub F cU,
        checkAllInstantiated cU F sub = true ->
        exists p, Permutation.Permutation (fromTo cU (length F) ++ p) (SUBST.Subst_domain sub).
      Proof.
        clear. induction F; simpl in *; eauto; intros.
        consider (SUBST.Subst_lookup cU sub); auto; intros. cut (In cU (SUBST.Subst_domain sub)); intros.
        eapply IHF in H0. destruct H0.
        cut (In cU x); intros. cut (exists p, Permutation.Permutation x (cU :: p)); intros.
        destruct H3. exists x0.
        rewrite <- H0. rewrite Permutation.Permutation_middle. apply Permutation.Permutation_app. reflexivity.
        symmetry; auto.
        clear -H2. induction x; inversion H2. subst. eauto. specialize (IHx H). destruct IHx. exists (a :: x0).
        rewrite H0. apply Permutation.perm_swap.

        cut (~In cU (fromTo (S cU) (length F))); intro.
        symmetry in H0; eapply Permutation.Permutation_in in H1. 2: eauto. eapply in_app_iff in H1. destruct H1; auto.
        exfalso; auto. eapply fromTo_none_less. 2: eauto. omega.

        apply SUBST.Subst_domain_iff. eauto.
      Qed.


      Lemma independent_well_typed : forall sub F cU,
        beq_nat (SUBST.Subst_size sub) (length F) = true ->
        checkAllInstantiated cU F sub = true ->
        forall u, u < cU -> SUBST.Subst_lookup u sub = None.
      Proof.
        clear. intros. symmetry in H. apply beq_nat_eq in H.
        rewrite SUBST.Subst_size_cardinal in H. cut (~In u (SUBST.Subst_domain sub)).
        intros. consider (SUBST.Subst_lookup u sub); auto. intros. exfalso. apply H2. eapply SUBST.Subst_domain_iff. eauto.

        apply checkAllInstantiated_perm in H0. destruct H0.
        intro. eapply Permutation.Permutation_in in H2. 2: symmetry; eauto. apply in_app_or in H2. destruct H2.
        eapply fromTo_none_less in H2; eauto.
        apply Permutation.Permutation_length in H0. rewrite app_length in H0. rewrite fromTo_length in H0. rewrite <- H in H0.
        destruct x. inversion H2. unfold uvar in *. simpl in *. omega.
      Qed.

      Lemma is_well_typed_mentionsU : forall U G (e : expr) t,
        is_well_typed (typeof_funcs funcs) U G e t = true ->
        forall u, mentionsU u e = true -> u < length U.
      Proof.
        clear. induction e; simpl; intros; try solve [ think; auto ].
        think. apply nth_error_Some_length in H. auto.
        { consider (nth_error (typeof_funcs funcs) f). intros. consider (equiv_dec t (TRange t0)); think; intros.
          clear H0. destruct t0; simpl in *. generalize dependent TDomain. revert H1.
          induction H; try congruence; destruct TDomain; simpl in *; think; try congruence; intros.
          consider (is_well_typed (typeof_funcs funcs) U G x t); intros. apply orb_true_iff in H1. destruct H1.
          eapply H; eauto. eapply IHForall; eauto. }
        { destruct t0. apply andb_true_iff in H. apply orb_true_iff in H0. destruct H. destruct H0; eauto. congruence. }
        { destruct t; try congruence. eapply IHe; eauto. }
      Qed.

      Lemma quant_nil : forall T ug U, quant (T := T) ug U nil = U.
      Proof.
        clear; destruct ug; simpl; intros; try reflexivity. rewrite app_nil_r; auto.
      Qed.

      Lemma split_WellTyped_sepConcl : forall a b,
        LEM.WellTyped_sepConcl (typeof_funcs funcs) (SE.typeof_preds preds) a (Concl b) = true ->
        SE.WellTyped_sexpr (typeof_funcs funcs) (SE.typeof_preds preds) nil a (LEM.Lhs b) = true /\
        SE.WellTyped_sexpr (typeof_funcs funcs) (SE.typeof_preds preds) nil a (LEM.Rhs b) = true.
      Proof.
        unfold LEM.WellTyped_sepConcl, LEM.Lhs, LEM.Rhs; intros.
        match goal with
          | [ H : (if ?X then _ else _) = true |- ?Y = true /\ _ ] =>
            change X with Y in H; destruct Y
        end; intuition.
      Qed.

      Theorem applicableOk : forall U_or_G U G facts lem args args' sub TS,
        LEM.sepLemmaD funcs preds nil nil lem ->
        Valid PC U G facts ->
        all2 (is_well_typed (typeof_funcs funcs) (typeof_env (types := types) U) (typeof_env G)) args TS = true ->
        all2 (is_well_typed (typeof_funcs funcs) nil (Foralls lem)) args' TS = true ->
        applicable unify_bound prover facts U_or_G (length U) (length G) lem args args' = Some sub ->
        args = map (liftInstantiate U_or_G (length U) (length G) 0 sub) args' /\
        let (lq,lh) := hash (LEM.Lhs lem) in
        let (rq,rh) := hash (LEM.Rhs lem) in
        ST.himp (ST_EXT.existsEach lq (fun lq =>
                      SE.sexprD funcs preds (quant U_or_G U (rev lq)) (quant (negb U_or_G) G (rev lq))
                      (sheapD (applySHeap (liftInstantiate U_or_G (length U) (length G) (length lq) sub) lh))))
                   (ST_EXT.existsEach rq (fun rq =>
                      SE.sexprD funcs preds (quant U_or_G U (rev rq)) (quant (negb U_or_G) G (rev rq))
                      (sheapD (applySHeap (liftInstantiate U_or_G (length U) (length G) (length rq) sub) rh))))
        /\ WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds)
              (quant U_or_G (typeof_env U) (rev lq)) (quant (negb U_or_G) (typeof_env G) (rev lq))
                (applySHeap (liftInstantiate U_or_G (length U) (length G) (length lq) sub) lh) = true
        /\ WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds)
              (quant U_or_G (typeof_env U) (rev rq)) (quant (negb U_or_G) (typeof_env G) (rev rq))
                (applySHeap (liftInstantiate U_or_G (length U) (length G) (length rq) sub) rh) = true.
      Proof.
        unfold applicable; intros.
        repeat match goal with
                 | [ H : match ?X with _ => _ end = _ |- _ ] =>
                   consider X; try congruence; intros
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
               end.
        eapply fold_left_2_opt_unify in H3. 2: apply SUBST.Subst_empty_WellTyped.
        Focus 3. eapply all2_impl. eassumption. intros. eapply is_well_typed_weaken with (u' := Foralls lem) (g' := nil).
        eassumption.
        Focus 2. rewrite all2_map_1. eapply all2_impl. eassumption. intros.
        rewrite <- typeof_env_length. eapply openForUnification_typed. eauto.
        think. split.
        { erewrite map_ext.
          2: intro; rewrite <- openForUnification_liftInstantiate; reflexivity.
          think. generalize (independent_well_typed _ _ H4 H6).
          revert H8. revert H1. clear. revert args'; revert TS.
          induction args; destruct args'; destruct TS; simpl in *; intros; think; try congruence.
          inversion H8. erewrite <- IHargs; eauto. f_equal. rewrite H3. symmetry. eapply exprInstantiate_noop; eauto.
          intros. eapply H.
          eapply is_well_typed_mentionsU in H2. 2: eauto. rewrite typeof_env_length in H2. omega. }
        { consider (hash (LEM.Lhs lem)); consider (hash (LEM.Rhs lem)); intros; think.
          generalize (@checkAllInstantiated_Subst_to_env_success _ _ _ _
            (typeof_env_WellTyped_env U) (typeof_env_WellTyped_env G) (typeof_funcs_WellTyped_funcs funcs) sub (Foralls lem) nil).
          rewrite app_nil_r in *. intro. destruct H11. rewrite typeof_env_length; auto. auto.

          rewrite typeof_env_length in H11. generalize H.
          eapply liftInstantiate_lemmaD with (U_or_G := U_or_G) (U := U) (G := G) in H; eauto. intro.
          eapply implyEach_sem in H.
          { rewrite SH.hash_denote in H. rewrite H10 in H.
            rewrite SH.hash_denote with (s := LEM.Rhs lem) in H. rewrite H9 in H. simpl in H.

            destruct H12. clear H13. unfold WellTyped_lemma in *. think.
            unfold SE.himp in H.
            rewrite HEAP_FACTS.SEP_FACTS.himp_existsEach_ST_EXT_existsEach in H.
            rewrite HEAP_FACTS.SEP_FACTS.himp_existsEach_ST_EXT_existsEach in H.
            split.
            { etransitivity. etransitivity; [ | eapply H ].
              apply ST_EXT.himp_existsEach; intros.

              erewrite <- applySHeap_wt_spec. reflexivity. intros. eauto. rewrite <- rev_length with (l := G0).
              eapply liftInstantiate_spec; eauto. rewrite <- typeof_env_app. auto.
              cutrewrite (s0 = snd (hash (LEM.Lhs lem))). rewrite typeof_env_app.
              rewrite typeof_env_rev.
              cutrewrite (typeof_env G0 = fst (hash (LEM.Lhs lem))).
              rewrite <- WellTyped_hash. simpl typeof_env. apply Subst_to_env_typeof_env in H11.
              eapply split_WellTyped_sepConcl in H13. destruct H13.
              rewrite <- H11. auto.

              rewrite H10; auto. rewrite H10; auto.

              apply ST_EXT.himp_existsEach. intros.
              rewrite <- applySHeap_wt_spec. reflexivity. intros. rewrite <- rev_length with (l := G0).
              eapply liftInstantiate_spec; eauto. rewrite <- typeof_env_app. auto.

              cutrewrite (s = snd (hash (LEM.Rhs lem))). rewrite typeof_env_app. rewrite typeof_env_rev.
              cutrewrite (typeof_env G0 = v). cutrewrite (v  = fst (hash (LEM.Rhs lem))).
              rewrite <- WellTyped_hash. simpl. apply Subst_to_env_typeof_env in H11. rewrite <- H11. auto.
              apply split_WellTyped_sepConcl in H13. destruct H13. auto.

              rewrite H9. auto. subst. reflexivity. rewrite H9. reflexivity. }
            {
            apply split_WellTyped_sepConcl in H13. destruct H13.
            rewrite WellTyped_hash in H14. rewrite WellTyped_hash in H13. think. simpl in *.
              rewrite (Subst_to_env_typeof_env _ _ _ _ _ H11) in *.
              split; (eapply applySHeap_typed_impl; [ | eauto ]).
              intros.
              eapply liftInstantiate_typed with (U_or_G := U_or_G) (U := typeof_env U) (G := typeof_env G) (sub := sub) in H15.
              rewrite rev_length in H15. repeat rewrite typeof_env_length in H15. eapply H15. eassumption.
              rewrite typeof_env_length. eassumption.
              intros.
              eapply liftInstantiate_typed with (U_or_G := U_or_G) (U := typeof_env U) (G := typeof_env G) (sub := sub) in H15.
              rewrite rev_length in H15. repeat rewrite typeof_env_length in H15. eapply H15. eassumption.
              rewrite typeof_env_length. eassumption. } }
          { destruct H12. clear H13. unfold WellTyped_lemma in H12. eapply allb_AllProvable; eauto.
            apply andb_true_iff in H12. destruct H12. apply split_WellTyped_sepConcl in H13. intuition.
            rewrite allb_map. eapply allb_impl. eauto. intros.
            simpl in *.
            generalize (@liftInstantiate_typed U_or_G (typeof_env U) (typeof_env G) nil x0 tvProp sub (Foralls lem)).
            simpl. rewrite (Subst_to_env_typeof_env _ _ _ _ _ H11) in *. intro. apply H16 in H13; auto.

            repeat rewrite quant_nil in *. repeat rewrite typeof_env_length in *. auto.
            rewrite typeof_env_length. auto. } }
      Qed.

      Theorem applicable_WellTyped : forall U_or_G tU tG facts lem args args' sub TS,
        LEM.WellTyped_sepLemma (typeof_funcs funcs) (SE.typeof_preds preds) lem = true ->
        all2 (is_well_typed (typeof_funcs funcs) tU tG) args TS = true ->
        all2 (is_well_typed (typeof_funcs funcs) nil (Foralls lem)) args' TS = true ->
        applicable unify_bound prover facts U_or_G (length tU) (length tG) lem args args' = Some sub ->
        args = map (liftInstantiate U_or_G (length tU) (length tG) 0 sub) args' /\
        let (lq,lh) := hash (LEM.Lhs lem) in
        let (rq,rh) := hash (LEM.Rhs lem) in
           WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds)
             (quant U_or_G tU (rev lq)) (quant (negb U_or_G) tG (rev lq))
                (applySHeap (liftInstantiate U_or_G (length tU) (length tG) (length lq) sub) lh) = true
        /\ WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds)
             (quant U_or_G tU (rev rq)) (quant (negb U_or_G) tG (rev rq))
                (applySHeap (liftInstantiate U_or_G (length tU) (length tG) (length rq) sub) rh) = true.
      Proof.
        unfold applicable; intros.
        repeat match goal with
                 | [ H : match ?X with _ => _ end = _ |- _ ] =>
                   consider X; try congruence; intros
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
               end.
        eapply fold_left_2_opt_unify in H2. 2: apply SUBST.Subst_empty_WellTyped.
        Focus 3. eapply all2_impl. eassumption. intros. eapply is_well_typed_weaken with (u' := Foralls lem) (g' := nil).
        eassumption.
        Focus 2. rewrite all2_map_1. eapply all2_impl. eassumption. intros.
        eapply openForUnification_typed. eauto. intuition.
        { erewrite map_ext.
          2: intro; rewrite <- openForUnification_liftInstantiate; reflexivity. apply andb_true_iff in H3.
          think. generalize (independent_well_typed _ _ H3 H6).
          revert H7. revert H0. clear. revert args'; revert TS.
          induction args; destruct args'; destruct TS; simpl in *; intros; think; try congruence.
          inversion H7. erewrite <- IHargs; eauto. f_equal. rewrite H3. symmetry. eapply exprInstantiate_noop; eauto.
          intros. eapply H.
          eapply is_well_typed_mentionsU in H2. 2: eauto. omega. }
        { consider (hash (LEM.Lhs lem)); consider (hash (LEM.Rhs lem)); intros; think.
          unfold WellTyped_lemma in *.
          repeat match goal with
                   | H : _ && _ = true |- _ => apply andb_true_iff in H; destruct H
                 end.
          { unfold LEM.WellTyped_sepLemma, WellTyped_lemma in H. apply andb_true_iff in H. destruct H.
            apply split_WellTyped_sepConcl in H10. rewrite WellTyped_hash in H10. rewrite WellTyped_hash in H10.
            destruct H10. rewrite H6 in *; rewrite H8 in *. simpl in *.
            rewrite app_nil_r in *.
            split; (eapply applySHeap_typed_impl; [ | eauto ]).
            intros.
            eapply liftInstantiate_typed with (U_or_G := U_or_G) (U := tU) (G := tG) (sub := sub) in H12; eauto.
            rewrite rev_length in *. auto.
            intros.
            eapply liftInstantiate_typed with (U_or_G := U_or_G) (U := tU) (G := tG) (sub := sub) in H12; eauto.
            rewrite rev_length in *. auto. } }
      Qed. (** TODO: This is duplicated from the full lemma **)

      Lemma ST_himp_heq_L : forall U G P Q S,
        SE.heq funcs preds U G P Q ->
        ST.himp (SE.sexprD funcs preds U G Q) S ->
        ST.himp (SE.sexprD funcs preds U G P) S.
      Proof.
        clear. intros. rewrite H. auto.
      Qed.

      Lemma Equal_remove_add_remove : forall T k (v : T) m,
        FM.Equal (FM.remove k (FM.add k v m)) (FM.remove k m).
      Proof.
        clear. intros. red. intros.
        repeat (rewrite MM.FACTS.add_o || rewrite MM.FACTS.remove_o).
        consider (MF.FACTS.eq_dec k y); auto.
      Qed.

      Lemma unfoldForward_vars : forall unify_bound facts P Q,
        unfoldForward unify_bound prover facts hs P = Some Q ->
        exists vars_ext, Vars Q = Vars P ++ vars_ext /\ UVars Q = UVars P.
      Proof.
        unfold unfoldForward. intros.
        repeat match goal with
                 | [ H : _ = Some _ |- _ ] => eapply findOk in H || eapply findWithRestOk in H
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
                 | [ H : exists x, _ |- _ ] => destruct H
                 | [ H : _ /\ _ |- _ ] => destruct H
                 | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                   (revert H; consider X; intros; try congruence) ; []
               end; simpl. eexists; intuition.
      Qed.

      Lemma hintSideD_In : forall hs,
        hintSideD hs -> forall x, In x hs -> LEM.sepLemmaD funcs preds nil nil x.
      Proof.
        clear. induction 1. inversion 1.
        intros. inversion H1; subst; auto.
      Qed.

      Opaque ST_EXT.existsEach.

      Lemma WellTyped_impures_find_fst_last : forall tU tG imps x0 x1 x2 k,
        WellTyped_impures (typeof_funcs funcs) (SE.typeof_preds preds) tU tG imps = true ->
        FM.find (elt:=list (exprs)) k imps = Some (x0 ++ x1 :: x2) ->
        match x0 ++ x2 with
          | nil => True
          | _ :: _ =>
            match nth_error (SE.typeof_preds preds) k with
              | Some ts =>
                allb (fun argss : list expr =>
                  all2 (is_well_typed (typeof_funcs funcs) tU tG) argss ts) (x0 ++ x2) = true
              | None => False
            end
        end.
      Proof.
        clear. intros.
        rewrite WellTyped_impures_eq in H. specialize (H _ _ H0).
        destruct x0; simpl in *; destruct (nth_error (SE.typeof_preds preds) k); think; auto. destruct x2; auto. contradiction.
        rewrite allb_app. rewrite allb_app in H1. think. simpl in *. think.
      Qed.

      Lemma with_left : forall (P Q R : Prop),
        (R -> P) ->
        R /\ Q ->
        P /\ Q.
      Proof. clear. firstorder. Qed.

      Lemma unfoldForward_WellTyped : forall facts P Q,
        unfoldForward unify_bound prover facts hs P = Some Q ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
      Proof.
        unfold unfoldForward; intros.
        repeat match goal with
                 | [ H : _ = Some _ |- _ ] => eapply findOk in H || eapply findWithRestOk in H
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
                 | [ H : exists x, _ |- _ ] => destruct H
                 | [ H : _ /\ _ |- _ ] => destruct H
                 | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                   (revert H; consider X; intros; try congruence) ; []
               end; simpl.
        eapply hintSideD_In in H; eauto using ForwardOk. destruct H. clear H3.
        rewrite WellTyped_sheap_eq in H0. apply andb_true_iff in H0. destruct H0.
        generalize (WellTyped_impures_find_fst_last _ _ _ _ H0 H2).
        rewrite WellTyped_impures_eq in H0. eapply H0 in H2.
        assert (match nth_error (SE.typeof_preds preds) f with
           | Some ts =>
               allb
                 (fun argss : list expr =>
                  all2
                    (is_well_typed (typeof_funcs funcs) (UVars P) (Vars P))
                    argss ts) (x0 ++ x1 :: x2) = true
           | None => False
           end). destruct x0; simpl in *; auto. clear H2.
        intros. rewrite <- WellTyped_sheap_star. apply andb_true_iff.  split.
        { rewrite WellTyped_sheap_eq; simpl. apply andb_true_iff; split.
          { rewrite WellTyped_impures_eq. intros.
            rewrite MF.FACTS.add_o in H7. destruct (MF.FACTS.eq_dec f k).
            { inversion H7; clear H7; subst; auto. destruct (x0 ++ x2); auto.
              generalize dependent (e :: l0). intros. destruct (nth_error (SE.typeof_preds preds) k); auto.
              eapply allb_impl; try eassumption. simpl; intros. eapply all2_impl; try eassumption.
              intros. rewrite <- app_nil_r with (l := UVars P). eapply is_well_typed_weaken. auto. }
            { eapply H0 in H7. destruct v0; auto. destruct (nth_error (SE.typeof_preds preds) k); auto.
              eapply allb_impl; try eassumption. simpl; intros. eapply all2_impl; try eassumption.
              intros; rewrite <- app_nil_r with (l := UVars P). eapply is_well_typed_weaken. auto. } }
          { eapply allb_impl; try eassumption. simpl; intros.
            rewrite <- app_nil_r with (l := UVars P). eapply is_well_typed_weaken. auto. } }
        { consider (nth_error (SE.typeof_preds preds) f); try contradiction; intros.
          eapply applicable_WellTyped with (TS := t)in H4; try eassumption. intuition.
          rewrite H5 in *. rewrite H1 in *. rewrite hash_Func in H9. intuition.
          rewrite allb_app in H6; simpl in H6. apply andb_true_iff in H6. destruct H6.
          consider (all2 (is_well_typed (typeof_funcs funcs) (UVars P) (Vars P)) x1 t); try congruence.
          unfold WellTyped_lemma in *.
          repeat match goal with
                   | H : _ && _ = _ |- _ => apply andb_true_iff in H; destruct H
                 end.
          apply split_WellTyped_sepConcl in H8. destruct H8.
          rewrite H1 in *. simpl in H8. rewrite H2 in *. auto. }
      Qed.

      Lemma unfoldForwardOk : forall meta_env vars_env facts P Q,
        WellTyped_env (UVars P) meta_env ->
        WellTyped_env (Vars P) vars_env ->
        Valid PC meta_env vars_env facts ->
        unfoldForward unify_bound prover facts hs P = Some Q ->
        forall (WT : WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (typeof_env meta_env) (typeof_env vars_env) (Heap P) = true),
        ST.himp (SE.sexprD funcs preds meta_env vars_env (sheapD (Heap P)))
                (ST_EXT.existsEach (skipn (length vars_env) (Vars Q))
                   (fun vars_ext : list {t : tvar & tvarD types t} =>
                    SE.sexprD funcs preds meta_env (vars_env ++ vars_ext) (sheapD (Heap Q))))
        /\ WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
      Proof.
        unfold unfoldForward. intros.
        repeat match goal with
                 | [ H : _ = Some _ |- _ ] => eapply findOk in H || eapply findWithRestOk in H
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
                 | [ H : exists x, _ |- _ ] => destruct H
                 | [ H : _ /\ _ |- _ ] => destruct H
                 | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                   (revert H; consider X; intros; try congruence) ; []
               end.
        destruct P; simpl in *.

        destruct Heap0; simpl in *.
        eapply with_left. intro.
        eapply ST_himp_heq_L with (Q := SE.Star (SH.sheapD {| SH.impures := FM.add f (x0 ++ x2) impures0
          ; SH.pures := pures0
          ; SH.other := other0
        |})
        (SE.Func f x1)). 2: eapply H5.
          { repeat rewrite SH.sheapD_def. simpl.
            rewrite SH.impuresD_Add with (f := f) (argss := x0 ++ x2) (i := FM.remove f (FM.add f (x0 ++ x2) impures0))
              (i' := FM.add f (x0 ++ x2) impures0).
            rewrite SH.impuresD_Add with (f := f) (argss := x0 ++ x1 :: x2) (i := FM.remove f impures0).
            heq_canceler.
            symmetry. rewrite impuresD_Equiv.
            2: rewrite Equal_remove_add_remove; reflexivity. reflexivity.
            red; intros. repeat (rewrite MM.FACTS.add_o || rewrite MM.FACTS.remove_o).
            destruct (MF.FACTS.eq_dec f y). subst; auto. auto. intro. apply MM.FACTS.remove_in_iff in H8. intuition congruence.
            red. intros. repeat (rewrite MM.FACTS.add_o || rewrite MM.FACTS.remove_o). consider (MF.FACTS.eq_dec f y); subst; auto.
            intro. apply MM.FACTS.remove_in_iff in H8. intuition congruence. }

          rewrite SEP_FACTS.heq_star_comm.
          assert (SE.WellTyped_sexpr (typeof_funcs funcs) (SE.typeof_preds preds) (typeof_env meta_env) (typeof_env vars_env)
            (SE.Func f x1) = true).
          { rewrite WellTyped_sheap_eq in WT. apply andb_true_iff in WT; intuition.
            rewrite WellTyped_impures_eq in H5. simpl in *. specialize (H5 _ _ H4).
            consider (x0 ++ x1 :: x2). intros. exfalso; destruct x0; simpl in *; congruence. intros.
            destruct (nth_error (SE.typeof_preds preds) f); try contradiction. rewrite <- H4 in *. rewrite allb_app in H9.
            simpl in *. think. }
          cut (SE.WellTyped_sexpr (typeof_funcs funcs) (SE.typeof_preds preds) (typeof_env meta_env) (typeof_env vars_env)
            (sheapD {| SH.impures := FM.add f (x0 ++ x2) impures0; SH.pures := pures0; SH.other := other0 |}) = true); intros.

          eapply hintSideD_In in H2; eauto using ForwardOk.
          assert (length UVars0 = length meta_env).
          { unfold WellTyped_env in *. subst. rewrite typeof_env_length. auto. }
          rewrite H9 in *.
          simpl in H5. consider (nth_error (SE.typeof_preds preds) f); intros.
          rewrite H0 in H6. rewrite typeof_env_length in H6. eapply applicableOk in H6; [ | eauto | eauto | eauto | ].
          Focus 2. destruct H2. unfold WellTyped_lemma in H2. think. apply split_WellTyped_sepConcl in H12.
          destruct H12. rewrite H3 in *. simpl in *. rewrite H5 in *. eapply H12.
          { destruct H6. rewrite H3 in *. rewrite SH.hash_Func in *. rewrite H7 in *.
            rewrite ST_EXT.existsEach_nil in *.
            rewrite SH.hash_denote with (s := SE.Func f x1). rewrite SH.hash_Func.
            unfold fst, snd, SE.existsEach. subst.
            rewrite HEAP_FACTS.applySHeap_singleton in *. simpl in *. rewrite app_nil_r in *. destruct H11. rewrite H6. clear H6.
            rewrite ST.heq_star_comm. rewrite ST_EXT.heq_pushIn. 
            Lemma WellTyped_env_length : forall a b, 
                                           WellTyped_env (types := types) a b ->
                                           length a = length b.
            Proof.
              unfold WellTyped_env, typeof_env. eauto with list_length.
            Qed.
            Hint Immediate WellTyped_env_length : list_length.
            rewrite rw_skipn_app; eauto with list_length.
            rewrite ST_EXT.existsEach_rev. split. 
            { eapply ST.heq_defn. eapply ST_EXT.heq_existsEach; intros.
              rewrite <- star_SHeap_denote. simpl. apply ST.heq_star_frame.
              { generalize dependent (sheapD {| SH.impures := FM.add f (x0 ++ x2) impures0;
                SH.pures := pures0;
                SH.other := other0 |}). clear; intros.
                generalize (SEP_FACTS.sexprD_weaken_wt funcs preds meta_env nil G s vars_env).
                rewrite app_nil_r. intro. rewrite H; try reflexivity. auto. }
              { rewrite rev_involutive. unfold WellTyped_env in *. subst. repeat rewrite typeof_env_length.
                cutrewrite (length v = length (rev G)). reflexivity.
                rewrite <- rev_length. rewrite <- H6. rewrite map_length. rewrite rev_length. reflexivity. } }
            { rewrite <- WellTyped_sheap_star. apply andb_true_iff. split.
              repeat rewrite WellTyped_sheap_eq in *; simpl in *. apply andb_true_iff in WT; destruct WT.
              apply andb_true_iff; split; auto.
              { apply WellTyped_impures_eq. intros. rewrite MM.FACTS.add_o in H13.
                consider (MF.FACTS.eq_dec f k); subst; intros. inversion H13; clear H13; subst.

                eapply WellTyped_impures_find_fst_last in H4; [ | eassumption ]. destruct (x0 ++ x2); auto.
                destruct (nth_error (SE.typeof_preds preds) k); auto. eapply allb_impl; try eassumption.
                rewrite H in *. rewrite H0 in *. clear; intros; simpl in *. unfold typeof_env in *.
                rewrite <- app_nil_r with (l := map (@projT1 _ _) meta_env).
                eapply all2_impl; try eassumption. intros. eapply is_well_typed_weaken. auto.
                rewrite WellTyped_impures_eq in H6. specialize (H6 _ _ H13). destruct v0; auto.
                destruct (nth_error (SE.typeof_preds preds) k); auto.
                generalize dependent (e :: v0). rewrite H. rewrite H0. clear. intros.
                eapply allb_impl; try eassumption; intros. eapply all2_impl; try eapply H; intros.
                rewrite <- app_nil_r with (l := typeof_env meta_env). eapply is_well_typed_weaken. auto. }
              { eapply allb_impl; try eassumption; intros. rewrite <- app_nil_r with (l := UVars0).
                eapply is_well_typed_weaken. rewrite H0. rewrite H. eapply H13. }
              { destruct H11. unfold WellTyped_env in *. rewrite H. rewrite H0. rewrite typeof_env_length. apply H11. } } }
          { clear - WT H4. rewrite <- WellTyped_sheap_WellTyped_sexpr. rewrite WellTyped_sheap_eq in *. think. simpl in *. 
            apply andb_true_iff. split; auto. apply WellTyped_impures_eq; intros.
            rewrite MM.FACTS.add_o in H1. destruct (MF.FACTS.eq_dec f k). think.
            rewrite WellTyped_impures_eq in H. specialize (H _ _ H4). destruct x0; simpl in *. destruct x2; auto.
            destruct (nth_error (SE.typeof_preds preds) k); auto. simpl in *. think.
            destruct (nth_error (SE.typeof_preds preds) k); auto. simpl in *. think. rewrite allb_app in *. simpl in H1. think; auto.
            rewrite WellTyped_impures_eq in H. apply H; auto. }
      Qed.

      Lemma ST_himp_heq_R : forall 
        (U G : env types) (P Q : SE.sexpr)
        (S : ST.hprop),
        SE.heq funcs preds U G P Q ->
        ST.himp S (SE.sexprD funcs preds U G Q) ->
        ST.himp S (SE.sexprD funcs preds U G P).
      Proof.
        clear. intros. rewrite H0. rewrite H. reflexivity.
      Qed.

      Lemma unfoldBackward_WellTyped : forall facts P Q,
        unfoldBackward unify_bound prover facts hs P = Some Q ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
      Proof.
        unfold unfoldBackward; intros.
        repeat match goal with
                 | [ H : _ = Some _ |- _ ] => eapply findOk in H || eapply findWithRestOk in H
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
                 | [ H : exists x, _ |- _ ] => destruct H
                 | [ H : _ /\ _ |- _ ] => destruct H
                 | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                   (revert H; consider X; intros; try congruence) ; []
               end; simpl.
        eapply hintSideD_In in H; eauto using BackwardOk. destruct H. clear H3.
        rewrite WellTyped_sheap_eq in H0. apply andb_true_iff in H0. destruct H0.
        generalize (WellTyped_impures_find_fst_last _ _ _ _ H0 H2).
        rewrite WellTyped_impures_eq in H0. eapply H0 in H2.
        assert (match nth_error (SE.typeof_preds preds) f with
           | Some ts =>
               allb
                 (fun argss : list expr =>
                  all2
                    (is_well_typed (typeof_funcs funcs) (UVars P) (Vars P))
                    argss ts) (x0 ++ x1 :: x2) = true
           | None => False
           end). destruct x0; simpl in *; auto. clear H2.
        intros. rewrite <- WellTyped_sheap_star. apply andb_true_iff.  split.
        { rewrite WellTyped_sheap_eq; simpl. apply andb_true_iff; split.
          { rewrite WellTyped_impures_eq. intros.
            rewrite MF.FACTS.add_o in H7. destruct (MF.FACTS.eq_dec f k).
            { inversion H7; clear H7; subst; auto. destruct (x0 ++ x2); auto.
              generalize dependent (e :: l0). intros. destruct (nth_error (SE.typeof_preds preds) k); auto.
              eapply allb_impl; try eassumption. simpl; intros. eapply all2_impl; try eassumption.
              intros. rewrite <- app_nil_r with (l := Vars P). eapply is_well_typed_weaken. auto. }
            { eapply H0 in H7. destruct v0; auto. destruct (nth_error (SE.typeof_preds preds) k); auto.
              eapply allb_impl; try eassumption. simpl; intros. eapply all2_impl; try eassumption.
              intros; rewrite <- app_nil_r with (l := Vars P). eapply is_well_typed_weaken. auto. } }
          { eapply allb_impl; try eassumption. simpl; intros.
            rewrite <- app_nil_r with (l := Vars P). eapply is_well_typed_weaken. auto. } }
        { consider (nth_error (SE.typeof_preds preds) f); try contradiction; intros.
          eapply applicable_WellTyped with (TS := t)in H4; try eassumption. intuition.
          rewrite H5 in *. rewrite H1 in *. rewrite hash_Func in H9. intuition.
          rewrite allb_app in H6; simpl in H6. apply andb_true_iff in H6. destruct H6.
          consider (all2 (is_well_typed (typeof_funcs funcs) (UVars P) (Vars P)) x1 t); try congruence.
          unfold WellTyped_lemma in *.
          repeat match goal with
                   | H : _ && _ = _ |- _ => apply andb_true_iff in H; destruct H
                 end.
          apply split_WellTyped_sepConcl in H8. destruct H8.
          rewrite H1 in *. simpl in *. rewrite H2 in *. auto. }
      Qed.

      Lemma unfoldBackwardOk : forall meta_env vars_env facts P Q,
        WellTyped_env (UVars P) meta_env ->
        WellTyped_env (Vars P) vars_env ->
        Valid PC meta_env vars_env facts ->
        unfoldBackward unify_bound prover facts hs P = Some Q ->
        forall (WT : WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (typeof_env meta_env) (typeof_env vars_env) (Heap P) = true),
        ST.himp (ST_EXT.existsEach (skipn (length meta_env) (UVars Q))
                  (fun meta_ext : list {t : tvar & tvarD types t} =>
                    SE.sexprD funcs preds (meta_env ++ meta_ext) vars_env (sheapD (Heap Q))))
                (SE.sexprD funcs preds meta_env vars_env (sheapD (Heap P)))
        /\ WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
      Proof.
        unfold unfoldBackward. intros.
        repeat match goal with
                 | [ H : _ = Some _ |- _ ] => eapply findOk in H || eapply findWithRestOk in H
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
                 | [ H : exists x, _ |- _ ] => destruct H
                 | [ H : _ /\ _ |- _ ] => destruct H
                 | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                   (revert H; consider X; intros; try congruence) ; []
               end.
        destruct P; simpl in *.

        destruct Heap0; simpl in *.
        eapply with_left. intro.
        eapply ST_himp_heq_R with (Q := SE.Star (SH.sheapD {| SH.impures := FM.add f (x0 ++ x2) impures0
          ; SH.pures := pures0
          ; SH.other := other0
        |})
        (SE.Func f x1)). 2: eapply H5.
          { repeat rewrite SH.sheapD_def. simpl.
            rewrite SH.impuresD_Add with (f := f) (argss := x0 ++ x2) (i := FM.remove f (FM.add f (x0 ++ x2) impures0))
              (i' := FM.add f (x0 ++ x2) impures0).
            rewrite SH.impuresD_Add with (f := f) (argss := x0 ++ x1 :: x2) (i := FM.remove f impures0).
            heq_canceler.
            symmetry. rewrite impuresD_Equiv.
            2: rewrite Equal_remove_add_remove; reflexivity. reflexivity.
            red; intros. repeat (rewrite MM.FACTS.add_o || rewrite MM.FACTS.remove_o).
            destruct (MF.FACTS.eq_dec f y). subst; auto. auto. intro. apply MM.FACTS.remove_in_iff in H8. intuition congruence.
            red. intros. repeat (rewrite MM.FACTS.add_o || rewrite MM.FACTS.remove_o). consider (MF.FACTS.eq_dec f y); subst; auto.
            intro. apply MM.FACTS.remove_in_iff in H8. intuition congruence. }

          rewrite SEP_FACTS.heq_star_comm.
          assert (SE.WellTyped_sexpr (typeof_funcs funcs) (SE.typeof_preds preds) (typeof_env meta_env) (typeof_env vars_env)
            (SE.Func f x1) = true).
          { rewrite WellTyped_sheap_eq in WT. apply andb_true_iff in WT; intuition.
            rewrite WellTyped_impures_eq in H5. simpl in *. specialize (H5 _ _ H4).
            consider (x0 ++ x1 :: x2). intros. exfalso; destruct x0; simpl in *; congruence. intros.
            destruct (nth_error (SE.typeof_preds preds) f); try contradiction. rewrite <- H4 in *. rewrite allb_app in H9.
            simpl in *. think. }
          cut (SE.WellTyped_sexpr (typeof_funcs funcs) (SE.typeof_preds preds) (typeof_env meta_env) (typeof_env vars_env)
            (sheapD {| SH.impures := FM.add f (x0 ++ x2) impures0; SH.pures := pures0; SH.other := other0 |}) = true); intros.

          eapply hintSideD_In in H2; eauto using BackwardOk.
          assert (length UVars0 = length meta_env).
          { unfold WellTyped_env in *. subst. rewrite typeof_env_length. auto. }
          rewrite H9 in *.
          simpl in H5. consider (nth_error (SE.typeof_preds preds) f); intros.
          rewrite H0 in H6. rewrite typeof_env_length in H6. eapply applicableOk in H6; [ | eauto | eauto | eauto | ].
          Focus 2. destruct H2. unfold WellTyped_lemma in H2. think.
          apply split_WellTyped_sepConcl in H12; destruct H12. rewrite H3 in *.
          simpl in *. rewrite H5 in *. eapply H13.
          { destruct H6. rewrite H3 in *. rewrite SH.hash_Func in *. rewrite H7 in *.
            rewrite ST_EXT.existsEach_nil in *.
            rewrite SH.hash_denote with (s := SE.Func f x1). rewrite SH.hash_Func.
            unfold fst, snd, SE.existsEach. subst.
            rewrite applySHeap_singleton in *. simpl in *. rewrite app_nil_r in *. destruct H11. rewrite <- H6. clear H6.
            rewrite ST.heq_star_comm. rewrite ST_EXT.heq_pushIn. rewrite rw_skipn_app; eauto with list_length.
            rewrite ST_EXT.existsEach_rev. split.
            { eapply ST.heq_defn. rewrite rev_involutive. eapply ST_EXT.heq_existsEach; intros.
              rewrite <- star_SHeap_denote. simpl. apply ST.heq_star_frame.
              { generalize dependent (sheapD {| SH.impures := FM.add f (x0 ++ x2) impures0;
                SH.pures := pures0;
                SH.other := other0 |}). clear; intros.
                generalize (SEP_FACTS.sexprD_weaken_wt funcs preds meta_env (rev G) nil s vars_env).
                rewrite app_nil_r. intro. rewrite H; try reflexivity. auto. }
              { unfold WellTyped_env in *. subst. repeat rewrite map_length.
                rewrite typeof_env_length. reflexivity. } }
            { rewrite <- WellTyped_sheap_star. apply andb_true_iff. split.
              repeat rewrite WellTyped_sheap_eq in *; simpl in *. apply andb_true_iff in WT; destruct WT.
              apply andb_true_iff; split; auto.
              { apply WellTyped_impures_eq. intros. rewrite MM.FACTS.add_o in H13.
                consider (MF.FACTS.eq_dec f k); subst; intros. inversion H13; clear H13; subst.

                eapply WellTyped_impures_find_fst_last in H4; [ | eassumption ]. destruct (x0 ++ x2); auto.
                destruct (nth_error (SE.typeof_preds preds) k); auto. eapply allb_impl; try eassumption.
                rewrite H in *. rewrite H0 in *. clear; intros; simpl in *. unfold typeof_env in *.
                rewrite <- app_nil_r with (l := map (@projT1 _ _) vars_env).
                eapply all2_impl; try eassumption. intros. eapply is_well_typed_weaken. auto.
                rewrite WellTyped_impures_eq in H6. specialize (H6 _ _ H13). destruct v0; auto.
                destruct (nth_error (SE.typeof_preds preds) k); auto.
                generalize dependent (e :: v0). rewrite H. rewrite H0. clear. intros.
                eapply allb_impl; try eassumption; intros. eapply all2_impl; try eapply H; intros.
                rewrite <- app_nil_r with (l := typeof_env vars_env). eapply is_well_typed_weaken. auto. }
              { eapply allb_impl; try eassumption; intros. rewrite <- app_nil_r with (l := Vars0).
                eapply is_well_typed_weaken. rewrite H0. rewrite H. eapply H13. }
              { destruct H11. unfold WellTyped_env in *. rewrite H. rewrite H0. rewrite typeof_env_length.
                eapply H6. } } }
          { clear - WT H4. rewrite <- WellTyped_sheap_WellTyped_sexpr. rewrite WellTyped_sheap_eq in *. think. simpl in *.
            apply andb_true_iff. split; auto. apply WellTyped_impures_eq; intros.
            rewrite MM.FACTS.add_o in H1. destruct (MF.FACTS.eq_dec f k). think.
            rewrite WellTyped_impures_eq in H. specialize (H _ _ H4). destruct x0; simpl in *. destruct x2; auto.
            destruct (nth_error (SE.typeof_preds preds) k); auto. simpl in *. think.
            destruct (nth_error (SE.typeof_preds preds) k); auto. simpl in *. think. rewrite allb_app in *. simpl in H1. think; auto.
            rewrite WellTyped_impures_eq in H. apply H; auto. }
      Qed.

      Lemma forwardLength : forall bound facts P Q r,
        forward bound facts P = (Q,r) ->
        exists vars_ext (* meta_ext *),
          Vars Q = Vars P ++ vars_ext /\
          UVars Q = UVars P (* ++ meta_ext *).
      Proof.
        clear. induction bound; intros; simpl in *; eauto.
        { inversion H; clear H; subst; exists nil; repeat rewrite app_nil_r; auto. }
        { consider (unfoldForward unify_bound prover facts hs P); intros.
          { eapply IHbound in H0. eapply unfoldForward_vars in H.
            repeat match goal with
                     | [ H : exists x, _ |- _ ] => destruct H
                     | [ H : _ /\ _ |- _ ] => destruct H
                     | [ H : _ = _ |- _ ] => rewrite H
                   end. repeat rewrite app_ass. eauto. }
          { inversion H0; clear H0; subst. exists nil; repeat rewrite app_nil_r; eauto. } }
      Qed.

      Lemma unfoldBackward_vars : forall unify_bound facts P Q,
        unfoldBackward unify_bound prover facts hs P = Some Q ->
        exists meta_ext, Vars Q = Vars P /\ UVars Q = UVars P ++ meta_ext.
      Proof.
        unfold unfoldBackward. intros.
        repeat match goal with
                 | [ H : _ = Some _ |- _ ] => eapply findOk in H || eapply findWithRestOk in H
                 | [ H : Some _ = Some _ |- _ ] => inversion H; clear H; subst
                 | [ H : exists x, _ |- _ ] => destruct H
                 | [ H : _ /\ _ |- _ ] => destruct H
                 | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                   (revert H; consider X; intros; try congruence) ; []
               end; simpl. eexists; intuition.
      Qed.

      Lemma backwardLength : forall bound facts P Q r,
        backward bound facts P = (Q,r) ->
        exists meta_ext,
          Vars Q = Vars P /\
          UVars Q = UVars P ++ meta_ext.
      Proof.
        clear. induction bound; intros; simpl in *; eauto.
        { inversion H; clear H; subst; exists nil; repeat rewrite app_nil_r; auto. }
        { consider (unfoldBackward unify_bound prover facts hs P); intros.
          { eapply IHbound in H0. eapply unfoldBackward_vars in H.
            repeat match goal with
                     | [ H : exists x, _ |- _ ] => destruct H
                     | [ H : _ /\ _ |- _ ] => destruct H
                     | [ H : _ = _ |- _ ] => rewrite H
                   end. repeat rewrite app_ass. eauto. }
          { inversion H0; clear H0; subst. exists nil; repeat rewrite app_nil_r; eauto. } }
      Qed.

      Theorem forward_WellTyped : forall bound facts P Q r,
        forward bound facts P = (Q,r) ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
      Proof.
        induction bound; simpl; intros; try subst; auto;
          repeat match goal with
                   | [ H : (_,_) = (_,_) |- _ ] => inversion H; clear H; subst
                   | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                     consider X; intros
                 end; auto.
        eapply unfoldForward_WellTyped in H; try eassumption. eapply IHbound; eauto.
      Qed.

      Theorem forwardOk : forall bound facts P Q r,
        forward bound facts P = (Q,r) ->
        forall meta_env vars_env,
        WellTyped_env (UVars P) meta_env -> (** meta_env instantiates the uvars **)
        WellTyped_env (Vars P) vars_env ->
        forall (WT : WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true),
        Valid PC meta_env vars_env facts ->
        ST.himp (SE.sexprD funcs preds meta_env vars_env (sheapD (Heap P)))
                (ST_EXT.existsEach (skipn (length vars_env) Q.(Vars)) (fun vars_ext : list { t : tvar & tvarD types t } =>
                  (SE.sexprD funcs preds meta_env (vars_env ++ vars_ext) (sheapD (Heap Q))))).
      Proof.
        induction bound; simpl; intros.
        { inversion H; clear H; subst; repeat split; try reflexivity.
          cutrewrite (skipn (length vars_env) (Vars Q) = nil).
          rewrite ST_EXT.existsEach_nil. rewrite app_nil_r. reflexivity.
          rewrite H1. rewrite <- typeof_env_length. eauto with list_length. }
        { revert H; case_eq (unfoldForward unify_bound prover facts hs P); intros.
          { subst. generalize H. eapply unfoldForwardOk in H; eauto.
            { destruct H. rewrite H.
              intros. eapply unfoldForward_vars in H5. do 2 destruct H5.
              specialize (IHbound _ _ _ _ H3).
              eapply forwardLength in H3.
              assert (length vars_env = length (Vars P)). rewrite H1. rewrite typeof_env_length. reflexivity.
              repeat match goal with
                       | [ H : _ = _ |- _ ] => rewrite H
                       | [ H : exists x, _ |- _ ] => destruct H
                       | [ H : _ /\ _ |- _ ] => destruct H
                       | [ |- _ ] => rewrite app_ass in *
                       | [ |- _ ] => rewrite rw_skipn_app by eauto with list_length
                     end.
              rewrite ST_EXT.existsEach_app; intros.
              eapply ST_EXT.himp_existsEach. intros.
              rewrite IHbound; try solve [  repeat match goal with
                                                     | [ H : _ = _ |- _ ] => rewrite H
                                                   end; auto ].
              think. rewrite rw_skipn_app.
              apply ST_EXT.himp_existsEach; intros.
              repeat (rewrite app_nil_r || rewrite app_ass). reflexivity.
              repeat rewrite app_length. rewrite typeof_env_length. subst. rewrite map_length. reflexivity.
              rewrite H5. repeat rewrite app_length. subst. rewrite H1. repeat rewrite map_length.
              unfold WellTyped_env. rewrite typeof_env_app. f_equal.

              repeat match goal with
                       | [ H : _ = _ |- _ ] => rewrite H in *
                     end. auto.
              rewrite <- app_nil_r with (l := meta_env); eapply Valid_weaken; eauto. }
            { rewrite <- WT. f_equal. rewrite H0. reflexivity. rewrite H1. reflexivity. } }
          { inversion H3; clear H3; subst. erewrite skipn_length_all.
            rewrite ST_EXT.existsEach_nil. rewrite app_nil_r. reflexivity.
            unfold WellTyped_env in *. rewrite H1. unfold typeof_env. reflexivity. } }
      Qed.

      Theorem backward_WellTyped : forall bound facts P Q r,
        backward bound facts P = (Q,r) ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
      Proof.
        induction bound; simpl; intros; try subst; auto;
          repeat match goal with
                   | [ H : (_,_) = (_,_) |- _ ] => inversion H; clear H; subst
                   | [ H : context [ match ?X with _ => _ end ] |- _ ] =>
                     consider X; intros
                 end; auto.
        eapply unfoldBackward_WellTyped in H; try eassumption. eapply IHbound; eauto.
      Qed.

      Theorem backwardOk : forall bound facts P Q meta_env vars_env r,
        backward bound facts P = (Q,r) ->
        WellTyped_env (UVars P) meta_env -> (** meta_env instantiates the uvars **)
        WellTyped_env (Vars P) vars_env ->
        WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
        Valid PC meta_env vars_env facts ->
        ST.himp (ST_EXT.existsEach (skipn (length meta_env) Q.(UVars)) (fun meta_ext : env types =>
                   (SE.sexprD funcs preds (meta_env ++ meta_ext) vars_env (sheapD (Heap Q)))))
                (SE.sexprD funcs preds meta_env vars_env (sheapD (Heap P))).
      Proof.
        induction bound; simpl; intros.
        { inversion H; clear H; subst. cutrewrite (skipn (length meta_env) (UVars Q) = nil). rewrite ST_EXT.existsEach_nil.
          rewrite app_nil_r. reflexivity. rewrite H0. rewrite <- typeof_env_length. eauto with list_length. }
        { consider (unfoldBackward unify_bound prover facts hs P); intros.
          { generalize H.
            eapply unfoldBackwardOk in H; eauto. intro.
            apply unfoldBackward_vars in H5. think.
            generalize (backwardLength _ _ _ H4); intro. think.
            rewrite app_ass. rewrite rw_skipn_app by (rewrite <- typeof_env_length; eauto with list_length).
            rewrite <- H. rewrite <- H7 in H6. rewrite <- H5 in H6. erewrite rw_skipn_app.
            2: rewrite <- typeof_env_length; reflexivity.
            rewrite ST_EXT.existsEach_app. eapply ST_EXT.himp_existsEach. intros.
            eapply IHbound in H4.
            Focus 2. rewrite H7. instantiate (1 := meta_env ++ G). unfold WellTyped_env. rewrite typeof_env_app.
            f_equal. symmetry; auto.
            Focus 2. rewrite H5. apply typeof_env_WellTyped_env.
            Focus 2. apply H6.
            Focus 2. rewrite <- app_nil_r with (l := vars_env). eapply Valid_weaken; auto.
            think. rewrite <- H4.
            rewrite rw_skipn_app. apply ST_EXT.himp_existsEach. intros. rewrite app_ass. reflexivity.
            repeat rewrite app_length. rewrite typeof_env_length. subst. rewrite map_length. reflexivity.
            rewrite <- H2. f_equal. symmetry; apply H0. symmetry; apply H1. }
          { inversion H4; clear H4; subst. cutrewrite (skipn (length meta_env) (UVars Q) = nil). rewrite ST_EXT.existsEach_nil.
            rewrite app_nil_r. reflexivity.  rewrite H0. rewrite <- typeof_env_length. eauto with list_length. } }
      Qed.
    End unfolder.
  End env.

  Section interface.
    Variable types : list type.
    Variable prover : ProverT.

    Definition refineForward (hs : hintSide) (bound : nat) (facts : Facts prover)
      (us : unfoldingState) : (unfoldingState) * bool :=
      let '(res,n) := forward hs prover bound facts us in
      (res, negb (EqNat.beq_nat n bound)).

    Definition refineBackward (hs : hintSide) (bound : nat) (facts : Facts prover)
      (us : unfoldingState) : (unfoldingState) * bool :=
      let '(res,n) := backward hs prover bound facts us in
      (res, negb (EqNat.beq_nat n bound)).

    Variable funcs : functions types.
    Variable preds : SE.predicates types.

    Theorem refineForward_Length : forall hints bound facts P Q b,
      refineForward hints bound facts P = (Q,b) ->
      exists vars_ext (* meta_ext *),
        Vars Q = Vars P ++ vars_ext /\
        UVars Q = UVars P (* ++ meta_ext *).
    Proof.
      unfold refineForward; intros.
      consider (forward hints prover bound facts P); intros.
      inversion H0; subst.
      eapply forwardLength; eassumption.
    Qed.


    Theorem refineForward_WellTyped : forall hints bound facts P Q b,
      Forall (LEM.sepLemmaD funcs preds nil nil) hints ->
      ProverT_correct prover funcs ->
      refineForward hints bound facts P = (Q,b) ->
      SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
      SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
    Proof.
      unfold refineForward; intros.
      consider (forward hints prover bound facts P); intros.
      inversion H2; clear H2; subst.
      eapply forward_WellTyped; eauto.
    Qed.

    Theorem refineForward_Ok : forall hints bound facts P Q b,
      Forall (LEM.sepLemmaD funcs preds nil nil) hints ->
      ProverT_correct prover funcs ->
      forall PC : ProverT_correct prover funcs,
      refineForward hints bound facts P = (Q,b) ->
      forall meta_env vars_env,
        WellTyped_env (UVars P) meta_env -> (** meta_env instantiates the uvars **)
        WellTyped_env (Vars P) vars_env ->
        forall (WT : SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true),
        Valid PC meta_env vars_env facts ->
        ST.himp
           (SE.sexprD funcs preds meta_env vars_env (SH.sheapD (Heap P)))
           (ST_EXT.existsEach (skipn (length vars_env) Q.(Vars)) (fun vars_ext : list { t : tvar & tvarD types t } =>
              (SE.sexprD funcs preds meta_env (vars_env ++ vars_ext) (SH.sheapD (Heap Q))))).
    Proof.
      unfold refineForward; intros.
      consider (forward hints prover bound facts P); intros.
      inversion H4; clear H4; subst.
      eapply forwardOk; eauto.
    Qed.


    Theorem refineBackward_Length : forall hints bound facts P Q b,
      refineBackward hints bound facts P = (Q, b) ->
      exists meta_ext,
        Vars Q = Vars P /\
        UVars Q = UVars P ++ meta_ext.
    Proof.
      unfold refineBackward; intros.
      consider (backward hints prover bound facts P); intros.
      inversion H0; clear H0; subst.
      eapply backwardLength; eauto.
    Qed.


    Theorem refineBackward_WellTyped : forall hints bound facts P Q b,
      Forall (LEM.sepLemmaD funcs preds nil nil) hints ->
      ProverT_correct prover funcs ->
        refineBackward hints bound facts P = (Q,b) ->
        SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
        SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars Q) (Vars Q) (Heap Q) = true.
    Proof.
      unfold refineBackward; intros.
      consider (backward hints prover bound facts P); intros.
      inversion H2; clear H2; subst.
      eapply backward_WellTyped; eauto.
    Qed.

    Theorem refineBackward_Ok : forall hints bound facts P Q meta_env vars_env b,
      Forall (LEM.sepLemmaD funcs preds nil nil) hints ->
      ProverT_correct prover funcs ->
      forall PC : ProverT_correct prover funcs,
      refineBackward hints bound facts P = (Q,b) ->
      WellTyped_env (UVars P) meta_env -> (** meta_env instantiates the uvars **)
      WellTyped_env (Vars P) vars_env ->
      SH.WellTyped_sheap (typeof_funcs funcs) (SE.typeof_preds preds) (UVars P) (Vars P) (Heap P) = true ->
      Valid PC meta_env vars_env facts ->
      ST.himp (ST_EXT.existsEach (skipn (length meta_env) Q.(UVars)) (fun meta_ext : env types =>
                      (SE.sexprD funcs preds (meta_env ++ meta_ext) vars_env (SH.sheapD (Heap Q)))))
                    (SE.sexprD funcs preds meta_env vars_env (SH.sheapD (Heap P))).
    Proof.
      unfold refineBackward; intros.
      consider (backward hints prover bound facts P); intros.
      inversion H5; clear H5; subst.
      eapply backwardOk; eauto.
    Qed.

  End interface.

End Make.
