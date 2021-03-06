{-# LANGUAGE QuasiQuotes #-}

-- | This module introduces functional for project creation.

module Summoner.Project
       ( generateProject
       ) where

import NeatInterpolation (text)
import System.Directory (setCurrentDirectory)

import Summoner.Ansi (errorMessage, infoMessage, successMessage)
import Summoner.Config (Config, ConfigP (..))
import Summoner.Decision (Decision (..), decisionToBool)
import Summoner.Default (currentYear, defaultGHC)
import Summoner.GhcVer (parseGhcVer, showGhcVer)
import Summoner.License (customizeLicense, fetchLicense, parseLicenseName)
import Summoner.Process ()
import Summoner.ProjectData (CustomPrelude (..), ProjectData (..))
import Summoner.Question (checkUniqueName, choose, chooseYesNo, falseMessage, query, queryDef,
                          queryManyRepeatOnFail, targetMessageWithText, trueMessage)
import Summoner.Source (fetchSource)
import Summoner.Template (createProjectTemplate)
import Summoner.Text (intercalateMap, packageToModule)
import Summoner.Tree (showTree, traverseTree)

-- | Generate the project.
generateProject :: Text -> Config -> IO ()
generateProject projectName Config{..} = do
    repo        <- checkUniqueName projectName
    -- decide cabal stack or both
    (cabal, stack) <- getCabalStack (cCabal, cStack)

    owner       <- queryDef "Repository owner: " cOwner
    description <- query "Short project description: "
    nm          <- queryDef "Author: " cFullName
    email       <- queryDef "Maintainer e-mail: " cEmail
    putText categoryText
    category <- query "Category: "
    licenseName  <- choose parseLicenseName "License: " $ ordNub (cLicense : universe)

    -- License creation
    fetchedLicense <- fetchLicense licenseName
    year <- currentYear
    let licenseText = customizeLicense licenseName fetchedLicense nm year

    -- Library/Executable/Tests/Benchmarks flags
    github <- decisionToBool cGitHub "GitHub integration"
    travis <- ifGithub github "Travis CI integration" cTravis
    appVey <- ifGithub (stack && github) "AppVeyor CI integration" cAppVey
    privat <- ifGithub github "private repository" cPrivate
    isLib  <- decisionToBool cLib "library target"
    isExe  <- let target = "executable target" in
              if isLib
              then decisionToBool cExe target
              else trueMessage target
    test   <- decisionToBool cTest "tests"
    bench  <- decisionToBool cBench "benchmarks"
    prelude <- if isLib then getPrelude else pure Nothing
    let base = case prelude of
            Nothing -> "base"
            Just _  -> "base-noprelude"

    let extensions = cExtensions

    let warnings = cWarnings

    putTextLn $ "The project will be created with the latest resolver for default GHC-" <> showGhcVer defaultGHC
    testedVersions <- sortNub . (defaultGHC :) <$> case cGhcVer of
        [] -> do
            putTextLn "Additionally you can specify versions of GHC to test with (space-separated): "
            infoMessage $ "Supported by 'summoner' GHCs: " <> intercalateMap " " showGhcVer universe
            queryManyRepeatOnFail parseGhcVer
        vers -> do
            putTextLn $ "Also these GHC versions will be added: " <> intercalateMap " " showGhcVer vers
            pure vers

    stylish <- case getLast cStylish of
        Nothing -> pure Nothing
        Just s  -> fetchSource s

    contributing <- case getLast cContributing of
        Nothing -> pure Nothing
        Just s  -> fetchSource s

    -- Create project data from all variables in scope
    let projectData = ProjectData{..}

    -- create stack project
    createProjectDirectory projectData
    -- create github repository and commit
    when github $ doGithubCommands projectData privat

 where
    ifGithub :: Bool -> Text -> Decision -> IO Bool
    ifGithub github target decision = if github
        then decisionToBool decision target
        else falseMessage target

    createProjectDirectory :: ProjectData -> IO ()
    createProjectDirectory projectData@ProjectData{..} = do
        let tree = createProjectTemplate projectData
        traverseTree tree
        successMessage "\nThe project with the following structure has been created:"
        putTextLn $ showTree tree
        setCurrentDirectory (toString repo)

    doGithubCommands :: ProjectData -> Bool -> IO ()
    doGithubCommands ProjectData{..} private = do
        -- Create the repository on Github.
        "git" ["init"]
        "hub" $ ["create", "-d", description, owner <> "/" <> repo]
             ++ ["-p" | private] -- creates private repository if asked so.
        -- Make a commit and push it.
        "git" ["add", "."]
        "git" ["commit", "-m", "Create the project"]
        "git" ["push", "-u", "origin", "master"]

    categoryText :: Text
    categoryText =
        [text|
        List of categories to choose from:

          * Control                    * Concurrency
          * Codec                      * Graphics
          * Data                       * Sound
          * Math                       * System
          * Parsing                    * Network
          * Text

          * Application                * Development
          * Compilers/Interpreters     * Testing
          * Web
          * Game
          * Utility

        |]

    getPrelude :: IO (Maybe CustomPrelude)
    getPrelude = case cPrelude of
        Last Nothing -> do
            let yesDo, noDo :: IO (Maybe CustomPrelude)
                yesDo = do
                    p <- query "Custom prelude package: "
                    m <- queryDef "Custom prelude module: " (packageToModule p)
                    successMessage $ "Custom prelude " <> p <> " will be used in the project"
                    pure $ Just $ Prelude p m
                noDo = pure Nothing
            chooseYesNo "custom prelude" yesDo noDo
        Last prelude@(Just (Prelude p _)) ->
            prelude <$ successMessage ("Custom prelude " <> p <> " will be used in the project")

    -- get what build tool to use in the project
    -- If user chose only one during CLI, we assume to use only that one.
    getCabalStack :: (Decision, Decision) -> IO (Bool, Bool)
    getCabalStack = \case
        (Idk, Idk) -> decisionToBool cCabal "cabal" >>= \c ->
            if c then decisionToBool cStack "stack" >>= \s -> pure (c, s)
            else stackMsg True >> pure (False, True)
        (Nop, Nop) -> errorMessage "Neither cabal nor stack was chosen" >> exitFailure
        (Yes, Yes) -> output (True, True)
        (Yes, _)   -> output (True, False)
        (_, Yes)   -> output (False, True)
        (Nop, Idk) -> output (False, True)
        (Idk, Nop) -> output (True, False)
      where
        output :: (Bool, Bool) -> IO (Bool, Bool)
        output x@(c, s) = cabalMsg c >> stackMsg s >> pure x

        cabalMsg c = targetMessageWithText c "Cabal" "used in this project"
        stackMsg c = targetMessageWithText c "Stack" "used in this project"
